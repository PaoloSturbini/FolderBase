import Foundation
import NaturalLanguage

/// Risultato di un embedding: il vettore e l'identificatore del provider che lo ha prodotto.
/// Il `providerID` include la lingua/modello: vettori con provider diversi NON sono confrontabili
/// (dimensioni diverse — es. Apple NL italiano=640, inglese=512), quindi la ricerca confronta
/// sempre e solo vettori dello stesso provider.
struct EmbeddingResult: Sendable {
    let providerID: String
    let vector: [Float]
}

/// Astrae il calcolo degli embedding: on-device (Apple), locale (Ollama) o cloud (BYOK OpenAI),
/// intercambiabili senza toccare il resto della pipeline. Vedi docs/AI-Indexing-Study.md.
/// È `async` perché i provider di rete fanno richieste HTTP; `Sendable` per poter attraversare
/// i confini di attore (es. `Task.detached` durante l'indicizzazione).
protocol TextEmbedder: Sendable {
    /// Embedding di un testo; nil se non calcolabile (lingua non supportata, rete assente…).
    func embed(_ text: String) async -> EmbeddingResult?

    /// Embedding di più testi in una volta, nello stesso ordine (elemento nil = non calcolabile).
    /// Default: sequenziale. I provider di rete lo sovrascrivono per inviare UNA sola richiesta
    /// (meno latenza e soprattutto meno rate-limit: prima si faceva una richiesta per chunk).
    func embedBatch(_ texts: [String]) async -> [EmbeddingResult?]
}

extension TextEmbedder {
    func embedBatch(_ texts: [String]) async -> [EmbeddingResult?] {
        var results: [EmbeddingResult?] = []
        results.reserveCapacity(texts.count)
        for text in texts {
            results.append(await embed(text))
        }
        return results
    }
}

/// Embedder **on-device** basato su `NLEmbedding.sentenceEmbedding` (framework NaturalLanguage,
/// nessuna rete, nessun costo). Rileva la lingua del testo e usa il modello corrispondente;
/// il `providerID` è `apple-nl-<lingua>`. Thread-safe: la cache dei modelli è protetta da lock
/// (indicizzazione e ricerca possono chiamarlo da thread diversi).
final class AppleNLEmbedder: TextEmbedder, @unchecked Sendable {
    static let shared = AppleNLEmbedder()

    private var cache: [String: NLEmbedding] = [:]
    private let lock = NSLock()

    /// Lingue con sentence embedding disponibile su cui ripiegare se il rilevamento fallisce.
    private let fallbackLanguages: [NLLanguage] = [.italian, .english]

    func embed(_ text: String) async -> EmbeddingResult? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let (language, embedding) = resolveEmbedding(for: trimmed),
              let vector = embedding.vector(for: trimmed) else { return nil }

        return EmbeddingResult(providerID: "apple-nl-\(language.rawValue)", vector: vector.map { Float($0) })
    }

    /// Sceglie la lingua: quella rilevata se ha un modello, altrimenti il primo fallback disponibile.
    private func resolveEmbedding(for text: String) -> (NLLanguage, NLEmbedding)? {
        let detected = dominantLanguage(of: text)
        if let embedding = embedding(for: detected) {
            return (detected, embedding)
        }
        for language in fallbackLanguages {
            if let embedding = embedding(for: language) {
                return (language, embedding)
            }
        }
        return nil
    }

    private func dominantLanguage(of text: String) -> NLLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage ?? .italian
    }

    /// Restituisce (e cachea) il modello di embedding per una lingua; nil se non disponibile.
    private func embedding(for language: NLLanguage) -> NLEmbedding? {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cache[language.rawValue] {
            return cached
        }
        guard let embedding = NLEmbedding.sentenceEmbedding(for: language) else {
            return nil
        }
        cache[language.rawValue] = embedding
        return embedding
    }
}

/// Suddivide il testo estratto in blocchi (chunk) di dimensione gestibile per l'embedding.
/// Le sentence embedding rendono meglio su porzioni brevi, quindi si accumulano frasi fino a
/// una soglia di caratteri, spezzando preferibilmente ai confini di frase.
enum TextChunker {
    static func chunks(from raw: String, targetChars: Int = 800, maxChunks: Int = 40) -> [String] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        let separators = CharacterSet(charactersIn: ".!?\n\r")
        let pieces = text
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !pieces.isEmpty else { return [String(text.prefix(targetChars))] }

        var chunks: [String] = []
        var current = ""
        for piece in pieces {
            if current.isEmpty {
                current = piece
            } else if current.count + piece.count + 2 <= targetChars {
                current += ". " + piece
            } else {
                chunks.append(current)
                if chunks.count >= maxChunks { return chunks }
                current = piece
            }
        }
        if !current.isEmpty, chunks.count < maxChunks {
            chunks.append(current)
        }
        return chunks
    }
}
