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

    private var task: Task<Void, Never>?

    /// Numero di chunk di contesto passati al modello.
    private let contextChunks = 8

    var isConfigured: Bool { ChatEngine.active() != nil }

    func reset() {
        task?.cancel()
        task = nil
        messages = []
        errorMessage = nil
        isBusy = false
    }

    func cancel() {
        task?.cancel()
        task = nil
        isBusy = false
    }

    /// Pone una domanda. `candidates` limita la ricerca (vuoto = tutto l'indice).
    func ask(_ question: String, candidates: Set<String>, store: MetadataStore) {
        let query = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isBusy else { return }
        guard ChatEngine.active() != nil else {
            errorMessage = L("chat.needProvider")
            return
        }

        errorMessage = nil
        isBusy = true
        messages.append(Message(role: .user, text: query, sources: []))
        let assistant = Message(role: .assistant, text: "", sources: [])
        messages.append(assistant)
        let assistantID = assistant.id
        let chunkCount = contextChunks

        task = Task { [weak self] in
            guard let self else { return }
            guard let chat = ChatEngine.active() else {
                self.fail(L("chat.needProvider"), id: assistantID)
                return
            }

            let embedder = EmbeddingEngine.active()
            guard let embedding = await embedder.embed(query) else {
                self.fail(L("chat.embedFail"), id: assistantID)
                return
            }

            let chunks = store.semanticChunks(queryVector: embedding.vector, providerID: embedding.providerID, candidates: candidates, limit: chunkCount)
            guard !chunks.isEmpty else {
                self.fail(L("chat.noContext"), id: assistantID)
                return
            }

            // Fonti distinte (per percorso) mostrate sotto la risposta.
            var seenPaths = Set<String>()
            var sources: [Source] = []
            for chunk in chunks where !seenPaths.contains(chunk.path) {
                seenPaths.insert(chunk.path)
                sources.append(Source(name: chunk.name, path: chunk.path))
            }
            self.setSources(sources, id: assistantID)

            let context = chunks.enumerated()
                .map { "[\($0.offset + 1)] \($0.element.name)\n\($0.element.text)" }
                .joined(separator: "\n\n")
            let userPrompt = "\(L("chat.contextLabel")):\n\(context)\n\n\(L("chat.questionLabel")): \(query)"

            do {
                for try await token in chat.stream(system: Self.systemPrompt, user: userPrompt) {
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

    static let systemPrompt = """
    Sei l'assistente di FolderBase. Rispondi ESCLUSIVAMENTE in base al contesto fornito (estratti di file dell'utente). \
    Se il contesto non contiene la risposta, dillo con chiarezza senza inventare. Cita le fonti pertinenti con la notazione [n]. \
    Rispondi nella stessa lingua della domanda, in modo chiaro e conciso.
    """

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
