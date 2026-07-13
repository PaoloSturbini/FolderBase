import Foundation

/// Chunk recuperato dall'indice per la chat RAG, con i punteggi che hanno determinato il ranking:
/// `semantic` (coseno, se disponibile per lo spazio del chunk), `lexical` (termini pesati IDF) e
/// `fused` (Reciprocal Rank Fusion dei due), su cui ragiona il `SourceSelector`.
struct RetrievedChunk: Sendable {
    let identity: String
    let path: String
    let name: String
    let text: String
    let semantic: Float?
    let lexical: Float
    let fused: Float
}

/// Seleziona le fonti migliori per la chat a partire dal pool di chunk recuperati dall'indice.
/// Ragiona a livello di DOCUMENTO, non di singolo chunk:
/// - aggrega i chunk per file e assegna un punteggio al documento;
/// - legge la data di modifica su disco e gli indizi di versione nel nome (v2, rev 3, date,
///   "finale", "aggiornato", "copia"…) per capire quale documento è più recente;
/// - riconosce le FAMIGLIE di versioni dello stesso documento e privilegia la più aggiornata,
///   retrocedendo le precedenti (che restano citabili ma non dominano il contesto);
/// - rileva le situazioni AMBIGUE — documenti diversi con nomi entrambi attinenti alla domanda e
///   punteggi quasi pari, o versioni con segnali di aggiornamento contrastanti — e in quei casi
///   chiede all'utente quale documento usare invece di scegliere a caso;
/// - applica diversità nella selezione finale (tetto di chunk per documento).
enum SourceSelector {

    /// Documento candidato come fonte, con i segnali usati per ordinare e spiegare la scelta.
    struct Document {
        let identity: String
        let path: String
        let name: String
        /// Punteggio aggregato del documento (miglior chunk + parte del secondo), eventualmente
        /// ridotto se il documento è stato retrocesso da una versione più recente.
        var score: Float
        /// Data di modifica del file su disco (nil se il file non è raggiungibile).
        let modifiedAt: Date?
        /// Numero di versione estratto dal nome ("v2", "rev 3", "(2)"…), se presente.
        let versionNumber: Int?
        /// Data estratta dal nome del file ("2026-03-12", "12-03-2026", "2026"), se presente.
        let dateInName: Date?
        /// Vero se nel pool esiste una versione più recente dello stesso documento.
        var isSuperseded: Bool = false
        /// Nome della versione più recente che lo sostituisce.
        var supersededBy: String? = nil

        /// Data "di riferimento" per la freschezza: la data nel nome vince sulla data su disco
        /// (un file copiato di recente può avere mtime nuovo pur essendo una versione vecchia).
        var freshnessDate: Date? { dateInName ?? modifiedAt }
    }

    /// Motivo per cui serve una domanda di chiarimento all'utente.
    enum ClarifyReason {
        /// Documenti DIVERSI, entrambi attinenti alla domanda, con punteggi quasi pari.
        case similarDocuments
        /// Versioni dello stesso documento con segnali di aggiornamento contrastanti
        /// (es. "v3" risulta più vecchio su disco di "v2": impossibile decidere da soli).
        case conflictingVersions
    }

    /// Esito della selezione: o i chunk da usare (con i documenti ordinati e annotati), o la
    /// richiesta di chiarimento con le opzioni da proporre all'utente.
    enum Outcome {
        case answer(chunks: [RetrievedChunk], documents: [Document])
        case clarify(options: [Document], reason: ClarifyReason)
    }

    /// Soglia di "quasi parità" tra documenti: il secondo è ambiguo se il suo punteggio è almeno
    /// questa frazione del primo.
    private static let tieThreshold: Float = 0.88
    /// Fattore di retrocessione per le versioni superate.
    private static let supersededPenalty: Float = 0.55

    static func select(question: String, pool: [RetrievedChunk], limit: Int, allowClarify: Bool) -> Outcome {
        guard !pool.isEmpty else { return .answer(chunks: [], documents: []) }

        // 1) Aggregazione per documento: punteggio = miglior chunk + 30% del secondo (un documento
        //    con più chunk pertinenti è più promettente di uno con un solo picco isolato).
        var order: [String] = []
        var chunksByDoc: [String: [RetrievedChunk]] = [:]
        for chunk in pool {
            if chunksByDoc[chunk.identity] == nil { order.append(chunk.identity) }
            chunksByDoc[chunk.identity, default: []].append(chunk)
        }
        var documents: [Document] = order.compactMap { identity in
            guard let chunks = chunksByDoc[identity]?.sorted(by: { $0.fused > $1.fused }), let first = chunks.first else { return nil }
            let second = chunks.dropFirst().first?.fused ?? 0
            let modifiedAt = (try? FileManager.default.attributesOfItem(atPath: first.path)[.modificationDate]) as? Date
            return Document(
                identity: identity,
                path: first.path,
                name: first.name,
                score: first.fused + 0.3 * second,
                modifiedAt: modifiedAt,
                versionNumber: versionNumber(in: first.name),
                dateInName: dateInName(first.name)
            )
        }

        // 2) Famiglie di versioni: documenti il cui nome, tolti marcatori di versione, date e
        //    numeri, coincide. Dentro una famiglia vince la versione più fresca; le altre vengono
        //    retrocesse. Se i segnali si contraddicono (numero di versione più alto ma file più
        //    vecchio su disco), si chiede all'utente.
        var families: [String: [Int]] = [:]
        for (index, document) in documents.enumerated() {
            let base = normalizedBase(document.name)
            guard base.count >= 3 else { continue }
            families[base, default: []].append(index)
        }
        for (_, members) in families where members.count > 1 {
            let sorted = members.sorted { isFresher(documents[$0], than: documents[$1]) }
            let winner = sorted[0]

            // Conflitto: il vincitore per numero di versione è nettamente più VECCHIO su disco di
            // un'altra versione (oltre un giorno di scarto) → i segnali non concordano.
            var conflicting = false
            if let winnerVersion = documents[winner].versionNumber,
               let winnerDate = documents[winner].modifiedAt {
                for member in sorted.dropFirst() {
                    if let memberVersion = documents[member].versionNumber, memberVersion < winnerVersion,
                       let memberDate = documents[member].modifiedAt,
                       memberDate.timeIntervalSince(winnerDate) > 86_400 {
                        conflicting = true
                        break
                    }
                }
            }
            if conflicting, allowClarify {
                let options = sorted.prefix(4).map { documents[$0] }
                return .clarify(options: Array(options), reason: .conflictingVersions)
            }

            for member in sorted.dropFirst() {
                documents[member].score *= supersededPenalty
                documents[member].isSuperseded = true
                documents[member].supersededBy = documents[winner].name
            }
        }

        // 3) Ambiguità tra documenti DIVERSI: se i primi due (di famiglie distinte) sono quasi
        //    pari E la domanda cita per nome entrambi allo stesso modo (nessuno dei due nomi
        //    discrimina), la scelta è dell'utente. Se invece i nomi non c'entrano con la domanda,
        //    i documenti sono solo entrambi pertinenti nel contenuto: si risponde usando entrambi.
        let ranked = documents.indices.sorted { documents[$0].score > documents[$1].score }
        if allowClarify, ranked.count > 1 {
            let top = documents[ranked[0]]
            let runnerUp = documents[ranked[1]]
            let topBase = normalizedBase(top.name)
            let sameFamily = topBase.count >= 3 && topBase == normalizedBase(runnerUp.name)
            if !sameFamily, !runnerUp.isSuperseded, runnerUp.score >= top.score * tieThreshold {
                let terms = MetadataStore.meaningfulTerms(from: question)
                let topHits = nameHits(top.name, terms: terms)
                let runnerHits = nameHits(runnerUp.name, terms: terms)
                if topHits > 0, topHits == runnerHits {
                    var options: [Document] = []
                    for index in ranked {
                        let document = documents[index]
                        guard !document.isSuperseded, document.score >= top.score * tieThreshold else { continue }
                        guard nameHits(document.name, terms: terms) == topHits else { continue }
                        options.append(document)
                        if options.count == 4 { break }
                    }
                    if options.count >= 2 {
                        return .clarify(options: options, reason: .similarDocuments)
                    }
                }
            }
        }

        // 4) Selezione finale con diversità: si scorrono i documenti in ordine di punteggio; il
        //    migliore può portare fino a 3 chunk, gli altri 2, le versioni superate 1. Se resta
        //    spazio, un secondo giro riempie con i chunk migliori rimasti.
        var selected: [RetrievedChunk] = []
        var selectedKeys = Set<String>()
        func key(_ chunk: RetrievedChunk) -> String { "\(chunk.identity)|\(chunk.text.hashValue)" }

        outer: for (rank, index) in ranked.enumerated() {
            let document = documents[index]
            let quota = document.isSuperseded ? 1 : (rank == 0 ? 3 : 2)
            let chunks = (chunksByDoc[document.identity] ?? []).sorted { $0.fused > $1.fused }
            for chunk in chunks.prefix(quota) {
                selected.append(chunk)
                selectedKeys.insert(key(chunk))
                if selected.count >= limit { break outer }
            }
        }
        if selected.count < limit {
            let leftovers = pool
                .filter { !selectedKeys.contains(key($0)) }
                .sorted { $0.fused > $1.fused }
            for chunk in leftovers {
                selected.append(chunk)
                if selected.count >= limit { break }
            }
        }

        let rankedDocuments = ranked.map { documents[$0] }
        return .answer(chunks: selected, documents: rankedDocuments)
    }

    // MARK: - Segnali di versione/freschezza nel nome del file

    /// Marcatori che indicano una variante/versione e non fanno parte del "nome base" del documento.
    private static let versionMarkers: Set<String> = [
        "final", "finale", "def", "definitivo", "definitiva", "aggiornato", "aggiornata", "agg",
        "nuovo", "nuova", "new", "old", "vecchio", "vecchia", "copia", "copy", "bozza", "draft",
        "ultimo", "ultima", "latest", "updated", "rev", "revisione", "version", "versione", "ver"
    ]

    /// Nome "base" di un documento: minuscolo, senza estensione, senza marcatori di versione,
    /// senza numeri puri (anni, contatori, date). Due file con lo stesso nome base sono con ogni
    /// probabilità versioni dello stesso documento ("Listino_2025.pdf" e "Listino_2026_v2.pdf").
    static func normalizedBase(_ name: String) -> String {
        let stem = (name as NSString).deletingPathExtension.lowercased()
        let separated = String(stem.map { $0.isLetter || $0.isNumber ? $0 : " " })
        let tokens = separated.components(separatedBy: " ").filter { token in
            guard !token.isEmpty else { return false }
            if versionMarkers.contains(token) { return false }
            if Int(token) != nil { return false }
            if token.range(of: "^(v|r|rev)\\d+$", options: .regularExpression) != nil { return false }
            return true
        }
        return tokens.joined(separator: " ")
    }

    /// Numero di versione estratto dal nome: "v2", "ver. 3", "versione 4", "rev 5", "(2)" finale.
    static func versionNumber(in name: String) -> Int? {
        let stem = (name as NSString).deletingPathExtension.lowercased()
        let patterns = [
            "(?:^|[^a-z0-9])v(?:er(?:sione|sion)?)?\\.?\\s*(\\d{1,3})(?:[^0-9]|$)",
            "(?:^|[^a-z0-9])rev(?:isione)?\\.?\\s*(\\d{1,3})(?:[^0-9]|$)",
            "\\((\\d{1,2})\\)\\s*$"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(stem.startIndex..., in: stem)
            guard let match = regex.firstMatch(in: stem, range: range), match.numberOfRanges > 1,
                  let captured = Range(match.range(at: 1), in: stem),
                  let value = Int(stem[captured]) else { continue }
            return value
        }
        return nil
    }

    /// Data estratta dal nome del file: "2026-03-12" (o 2026_03_12, 20260312), "12-03-2026",
    /// oppure il solo anno "2026" (interpretato come 1° gennaio, sufficiente per confronti).
    static func dateInName(_ name: String) -> Date? {
        let stem = (name as NSString).deletingPathExtension

        func date(year: Int, month: Int, day: Int) -> Date? {
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            return Calendar(identifier: .gregorian).date(from: components)
        }
        func firstMatch(_ pattern: String) -> [Int]? {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            let range = NSRange(stem.startIndex..., in: stem)
            guard let match = regex.firstMatch(in: stem, range: range) else { return nil }
            var values: [Int] = []
            for index in 1..<match.numberOfRanges {
                guard let captured = Range(match.range(at: index), in: stem),
                      let value = Int(stem[captured]) else { return nil }
                values.append(value)
            }
            return values
        }

        // yyyy-mm-dd (separatori -, _, ., spazio o nessuno)
        if let v = firstMatch("(20\\d{2})[-_. ]?(0[1-9]|1[0-2])[-_. ]?(0[1-9]|[12]\\d|3[01])(?:[^0-9]|$)"), v.count == 3 {
            return date(year: v[0], month: v[1], day: v[2])
        }
        // dd-mm-yyyy
        if let v = firstMatch("(?:^|[^0-9])(0?[1-9]|[12]\\d|3[01])[-_. ](0?[1-9]|1[0-2])[-_. ](20\\d{2})(?:[^0-9]|$)"), v.count == 3 {
            return date(year: v[2], month: v[1], day: v[0])
        }
        // Solo anno
        if let v = firstMatch("(?:^|[^0-9])(20\\d{2})(?:[^0-9]|$)"), v.count == 1 {
            return date(year: v[0], month: 1, day: 1)
        }
        return nil
    }

    /// Confronto di freschezza tra due documenti: prima il numero di versione (se entrambi ne
    /// hanno uno), poi la data (nel nome, o su disco), infine il punteggio di pertinenza.
    static func isFresher(_ a: Document, than b: Document) -> Bool {
        if let va = a.versionNumber, let vb = b.versionNumber, va != vb { return va > vb }
        let da = a.freshnessDate ?? .distantPast
        let db = b.freshnessDate ?? .distantPast
        if da != db { return da > db }
        return a.score > b.score
    }

    /// Quanti termini significativi della domanda compaiono nel nome del file (esatti o prefisso).
    static func nameHits(_ name: String, terms: [String]) -> Int {
        guard !terms.isEmpty else { return 0 }
        let tokens = Set(name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        var hits = 0
        for term in terms where tokens.contains(where: { $0 == term || $0.hasPrefix(term) }) {
            hits += 1
        }
        return hits
    }
}
