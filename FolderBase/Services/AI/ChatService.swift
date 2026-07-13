import Foundation
import Combine

/// Orchestrazione della chat RAG: recupera i chunk più pertinenti (ricerca semantica),
/// costruisce il prompt con le fonti e trasmette in streaming la risposta dell'LLM.
@MainActor
final class ChatService: ObservableObject {
    struct Source: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let path: String
    }

    struct Message: Identifiable {
        let id = UUID()
        let role: Role
        var text: String
        var sources: [Source]
    }

    enum Role {
        case user
        case assistant
    }

    @Published private(set) var messages: [Message] = []
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?

    /// Ambito corrente della chat: insieme di identità su cui cercare (vuoto = tutto l'indice) e
    /// un'etichetta descrittiva mostrata nell'header ("Tutto l'indice", "Cartella: …", "File: …").
    @Published private(set) var scopeLabel: String = ""
    private var candidates: Set<String> = []
    /// Ultima domanda posta, per il pulsante "Rilancia".
    @Published private(set) var lastQuestion: String?

    /// Domanda di chiarimento in sospeso: quando il retrieval trova documenti diversi o versioni
    /// in conflitto, l'assistente chiede quale usare e memorizza qui la domanda originale e le
    /// opzioni proposte. La risposta dell'utente (numero, nome, "tutti", "il più recente") viene
    /// interpretata da `resolveClarification` e rilancia la domanda originale sul sottoinsieme scelto.
    private struct PendingClarification {
        let question: String
        let options: [SourceSelector.Document]
    }
    private var pendingClarification: PendingClarification?

    private var task: Task<Void, Never>?

    var isConfigured: Bool { ChatEngine.active() != nil }
    var canRerun: Bool { lastQuestion != nil && !isBusy }
    var hasConversation: Bool { !messages.isEmpty }

    /// Imposta l'ambito della chat e azzera la conversazione (nuovo contesto = nuova chat).
    func configure(candidates: Set<String>, scopeLabel: String) {
        self.candidates = candidates
        self.scopeLabel = scopeLabel
        reset()
    }

    func reset() {
        task?.cancel()
        task = nil
        messages = []
        errorMessage = nil
        isBusy = false
        lastQuestion = nil
        pendingClarification = nil
    }

    func cancel() {
        task?.cancel()
        task = nil
        isBusy = false
    }

    /// Ripete l'ultima domanda posta (utile dopo un cambio di modello o una reindicizzazione).
    func rerun(store: MetadataStore) {
        guard let question = lastQuestion else { return }
        ask(question, store: store)
    }

    /// Pone una domanda usando l'ambito corrente (`candidates`, vuoto = tutto l'indice).
    /// Se è in sospeso una domanda di chiarimento, prova prima a interpretare il messaggio come
    /// scelta tra le opzioni proposte; altrimenti lo tratta come nuova domanda.
    func ask(_ question: String, store: MetadataStore) {
        let query = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isBusy else { return }
        guard ChatEngine.active() != nil else {
            errorMessage = L("chat.needProvider")
            return
        }

        if let pending = pendingClarification {
            pendingClarification = nil
            if let chosen = Self.resolveClarification(reply: query, options: pending.options) {
                messages.append(Message(role: .user, text: query, sources: []))
                run(question: pending.question, store: store, restrictedTo: chosen, allowClarify: false)
                return
            }
            // Risposta non riconducibile alle opzioni: è una nuova domanda, si prosegue normalmente.
        }

        messages.append(Message(role: .user, text: query, sources: []))
        run(question: query, store: store, restrictedTo: nil, allowClarify: true)
    }

    /// Esegue il ciclo retrieval → (eventuale chiarimento) → risposta. `restrictedTo` limita la
    /// ricerca ai documenti scelti dall'utente dopo un chiarimento; `allowClarify` evita che un
    /// chiarimento ne generi un altro all'infinito.
    private func run(question: String, store: MetadataStore, restrictedTo: Set<String>?, allowClarify: Bool) {
        errorMessage = nil
        isBusy = true
        lastQuestion = question
        // Storico (turni precedenti) per il multi-turn: esclude il messaggio utente appena
        // aggiunto, e limitato agli ultimi turni per non gonfiare il prompt.
        let history = Array(messages.dropLast().suffix(Self.historyTurns)).map {
            ChatTurn(role: $0.role == .user ? "user" : "assistant", content: $0.text)
        }
        let assistant = Message(role: .assistant, text: "", sources: [])
        messages.append(assistant)
        let assistantID = assistant.id
        let chunkCount = AIProviderSettings.chatContextChunks
        let scope = restrictedTo ?? self.candidates

        task = Task { [weak self] in
            guard let self else { return }
            guard let chat = ChatEngine.active() else {
                self.fail(L("chat.needProvider"), id: assistantID)
                return
            }

            // Vettore della domanda per OGNI spazio (lingua/motore) presente nell'indice, così la
            // ricerca può raggiungere anche documenti in una lingua diversa dalla domanda (es. domanda
            // in italiano, documenti in inglese). Con un motore multilingue (Ollama/OpenAI) lo spazio
            // è unico e copre già tutte le lingue.
            let embedder = EmbeddingEngine.active()
            let spaces = await store.indexedProviderIDsAsync()
            let queries = await embedder.embedForSpaces(question, providerIDs: spaces)

            // Pool ampio (più del necessario): serve al SourceSelector per vedere le alternative,
            // riconoscere versioni dello stesso documento e rilevare ambiguità.
            // Non si fallisce se manca l'embedding: il recupero per parole chiave è comunque possibile.
            // La scansione vettoriale + scoring girano fuori dal main thread (vedi semanticChunksAsync).
            let poolLimit = max(chunkCount * 4, 24)
            let pool = await store.semanticChunksAsync(query: question, queries: queries, candidates: scope, limit: poolLimit)
            guard !pool.isEmpty else {
                self.fail(L("chat.noContext"), id: assistantID)
                return
            }

            switch SourceSelector.select(question: question, pool: pool, limit: chunkCount, allowClarify: allowClarify) {
            case .clarify(let options, let reason):
                self.presentClarification(options: options, reason: reason, question: question, id: assistantID)
                return

            case .answer(let chunks, let documents):
                guard !chunks.isEmpty else {
                    self.fail(L("chat.noContext"), id: assistantID)
                    return
                }

                // Fonti numerate per DOCUMENTO: lo stesso numero [n] identifica il documento sia
                // nel contesto passato al modello sia nell'elenco mostrato sotto la risposta.
                var numberByIdentity: [String: Int] = [:]
                var sources: [Source] = []
                for chunk in chunks where numberByIdentity[chunk.identity] == nil {
                    numberByIdentity[chunk.identity] = sources.count + 1
                    sources.append(Source(name: chunk.name, path: chunk.path))
                }
                self.setSources(sources, id: assistantID)

                // Contesto con la data di aggiornamento di ogni fonte, così il modello può
                // ragionare su quale informazione è più recente in caso di contraddizioni.
                let dateByIdentity = Dictionary(uniqueKeysWithValues: documents.map { ($0.identity, $0.freshnessDate) })
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                let context = chunks.map { chunk -> String in
                    var header = "[\(numberByIdentity[chunk.identity] ?? 0)] \(chunk.name)"
                    if let date = dateByIdentity[chunk.identity] ?? nil {
                        header += " — \(L("chat.source.updated")) \(formatter.string(from: date))"
                    }
                    return "\(header)\n\(chunk.text)"
                }.joined(separator: "\n\n")

                // Note sulle versioni: se una fonte è stata retrocessa perché ne esiste una più
                // recente, lo si dice al modello (che può segnalarlo nella risposta).
                let notes = documents
                    .filter { $0.isSuperseded && numberByIdentity[$0.identity] != nil }
                    .compactMap { document -> String? in
                        guard let newer = document.supersededBy else { return nil }
                        return L("chat.note.newerUsed")
                            .replacingOccurrences(of: "{old}", with: document.name)
                            .replacingOccurrences(of: "{new}", with: newer)
                    }
                let contextBlock = notes.isEmpty ? context : context + "\n\n" + notes.joined(separator: "\n")
                let userPrompt = "\(L("chat.contextLabel")):\n\(contextBlock)\n\n\(L("chat.questionLabel")): \(question)"

                // Turni: storico precedente + la domanda corrente arricchita col contesto recuperato.
                let turns = history + [ChatTurn(role: "user", content: userPrompt)]

                do {
                    for try await token in chat.stream(system: Self.systemPrompt, turns: turns) {
                        if Task.isCancelled { break }
                        self.append(token, id: assistantID)
                    }
                    self.isBusy = false
                    self.task = nil
                } catch {
                    if self.text(for: assistantID).isEmpty {
                        self.fail(L("chat.streamFail"), id: assistantID)
                    } else {
                        self.isBusy = false
                        self.task = nil
                    }
                }
            }
        }
    }

    // MARK: - Chiarimenti sulle fonti (documenti diversi o versioni in conflitto)

    /// Mostra la domanda di chiarimento con l'elenco delle opzioni (nome, versione, data) e mette
    /// in sospeso la domanda originale in attesa della scelta dell'utente.
    private func presentClarification(options: [SourceSelector.Document], reason: SourceSelector.ClarifyReason, question: String, id: UUID) {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        var lines: [String] = [L(reason == .conflictingVersions ? "chat.clarify.versions" : "chat.clarify.similar"), ""]
        for (index, document) in options.enumerated() {
            var details: [String] = []
            if let version = document.versionNumber { details.append("v\(version)") }
            if let date = document.freshnessDate { details.append("\(L("chat.source.updated")) \(formatter.string(from: date))") }
            let suffix = details.isEmpty ? "" : " (\(details.joined(separator: ", ")))"
            lines.append("\(index + 1). \(document.name)\(suffix)")
        }
        lines.append("")
        lines.append(L("chat.clarify.question"))

        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].text = lines.joined(separator: "\n")
            messages[index].sources = options.map { Source(name: $0.name, path: $0.path) }
        }
        pendingClarification = PendingClarification(question: question, options: options)
        isBusy = false
        task = nil
    }

    /// Interpreta la risposta a una domanda di chiarimento: numeri delle opzioni ("1", "1 e 3"),
    /// "tutti"/"all", "il più recente"/"latest", oppure il nome (anche parziale) di un documento.
    /// Ritorna nil se il messaggio non sembra una scelta (verrà trattato come nuova domanda).
    static func resolveClarification(reply: String, options: [SourceSelector.Document]) -> Set<String>? {
        let lower = reply.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !options.isEmpty else { return nil }

        // Solo numeri (ed eventuali congiunzioni): "2", "1 e 3", "1, 2".
        let connectors: Set<String> = ["e", "and", "o", "or", ","]
        let tokens = lower.components(separatedBy: CharacterSet(charactersIn: " ,;")).filter { !$0.isEmpty }
        if !tokens.isEmpty, tokens.allSatisfy({ Int($0) != nil || connectors.contains($0) }) {
            let picked = tokens.compactMap { Int($0) }.filter { $0 >= 1 && $0 <= options.count }
            if !picked.isEmpty { return Set(picked.map { options[$0 - 1].identity }) }
            return nil
        }

        let wordCount = tokens.count
        if wordCount <= 5 {
            if ["tutti", "tutte", "entrambi", "entrambe", "all", "both"].contains(where: lower.contains) {
                return Set(options.map(\.identity))
            }
            if ["recente", "nuovo", "nuova", "aggiornato", "aggiornata", "newest", "latest", "recent"].contains(where: lower.contains) {
                let newest = options.max { ($0.freshnessDate ?? .distantPast) < ($1.freshnessDate ?? .distantPast) }
                return newest.map { Set([$0.identity]) }
            }
        }

        // Nome del documento (anche parziale, min. 3 caratteri): unica opzione compatibile.
        if lower.count >= 3 {
            let matches = options.filter { option in
                let name = option.name.lowercased()
                return name.contains(lower) || lower.contains(name)
            }
            if matches.count == 1 { return Set([matches[0].identity]) }
        }
        return nil
    }

    /// Numero massimo di turni di storico (messaggi) inviati al modello per il multi-turn.
    private static let historyTurns = 8

    static let systemPrompt = """
    Sei l'assistente di FolderBase. Rispondi ESCLUSIVAMENTE in base al contesto fornito (estratti di file dell'utente). \
    Ogni fonte è numerata [n] e può riportare la data di aggiornamento del file. \
    Se più fonti si contraddicono, dai la precedenza alle informazioni con data più recente e segnala esplicitamente la discrepanza (quale fonte dice cosa). \
    Se le fonti in conflitto non hanno date che permettano di decidere, dillo e riporta entrambe le versioni. \
    Se il contesto non contiene la risposta, dillo con chiarezza senza inventare. Cita le fonti pertinenti con la notazione [n]. \
    Rispondi nella stessa lingua della domanda, in modo chiaro e conciso.
    """

    // MARK: - Esportazione / copia della conversazione

    /// Conversazione in Markdown (domande, risposte e fonti citate), per esportazione o copia.
    func transcriptMarkdown() -> String {
        var lines: [String] = ["# \(L("chat.title"))"]
        if !scopeLabel.isEmpty { lines.append("_\(L("chat.scope.label")): \(scopeLabel)_") }
        lines.append("")
        for message in messages {
            let heading = message.role == .user ? L("chat.export.you") : L("chat.export.assistant")
            lines.append("## \(heading)")
            lines.append(message.text)
            if !message.sources.isEmpty {
                lines.append("")
                lines.append("**\(L("chat.sources"))**")
                for (index, source) in message.sources.enumerated() {
                    lines.append("- [\(index + 1)] \(source.name) — `\(source.path)`")
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Mutazioni del messaggio in streaming

    private func append(_ token: String, id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text += token
    }

    private func setSources(_ sources: [Source], id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].sources = sources
    }

    private func text(for id: UUID) -> String {
        messages.first(where: { $0.id == id })?.text ?? ""
    }

    private func fail(_ message: String, id: UUID) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].text = message
        }
        errorMessage = message
        isBusy = false
        task = nil
    }
}
