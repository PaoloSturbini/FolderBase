import Foundation
import OSLog

private let embeddingLog = Logger(subsystem: "com.paolosturbini.folderbase", category: "Embedding")

private func validEmbeddingResponse(_ response: URLResponse, provider: String) -> Bool {
    guard let http = response as? HTTPURLResponse else {
        embeddingLog.error("Risposta non HTTP dal provider \(provider, privacy: .public)")
        return false
    }
    guard http.statusCode == 200 else {
        embeddingLog.error("Provider \(provider, privacy: .public): HTTP \(http.statusCode)")
        return false
    }
    return true
}

/// Embedder tramite endpoint locale compatibile Ollama (`POST /api/embeddings`).
/// Privato e offline: i contenuti non lasciano la macchina. Richiede Ollama in esecuzione.
struct OllamaEmbedder: TextEmbedder {
    let baseURL: String
    let model: String

    func embed(_ text: String) async -> EmbeddingResult? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let base = baseURL.trimmingCharacters(in: .whitespaces).hasSuffix("/")
            ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: base + "/api/embeddings") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "prompt": trimmed])
        request.timeoutInterval = 30

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              validEmbeddingResponse(response, provider: "Ollama"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let array = json["embedding"] as? [Double], !array.isEmpty else { return nil }

        return EmbeddingResult(providerID: "ollama-\(model)", vector: array.map { Float($0) })
    }

    /// Il vecchio endpoint Ollama non accetta batch: usa una finestra limitata di quattro
    /// richieste, mantenendo l'ordine e senza saturare il servizio locale.
    func embedBatch(_ texts: [String]) async -> [EmbeddingResult?] {
        var results: [EmbeddingResult?] = Array(repeating: nil, count: texts.count)
        for start in stride(from: 0, to: texts.count, by: 4) {
            let end = min(start + 4, texts.count)
            await withTaskGroup(of: (Int, EmbeddingResult?).self) { group in
                for index in start..<end {
                    group.addTask { (index, await embed(texts[index])) }
                }
                for await (index, result) in group { results[index] = result }
            }
        }
        return results
    }
}

/// Embedder cloud OpenAI (BYOK, `POST /v1/embeddings`). La chiave è passata dal chiamante
/// (letta dal Portachiavi). ATTENZIONE: il testo viene inviato ai server OpenAI.
struct OpenAIEmbedder: TextEmbedder {
    let apiKey: String
    let model: String

    func embed(_ text: String) async -> EmbeddingResult? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !apiKey.isEmpty,
              let url = URL(string: "https://api.openai.com/v1/embeddings") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "input": trimmed])
        request.timeoutInterval = 30

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              validEmbeddingResponse(response, provider: "OpenAI"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]],
              let first = dataArray.first,
              let array = first["embedding"] as? [Double], !array.isEmpty else { return nil }

        return EmbeddingResult(providerID: "openai-\(model)", vector: array.map { Float($0) })
    }

    /// Batch: un'unica richiesta con `input` = array di testi. OpenAI ritorna gli embedding con un
    /// campo `index` che ne indica la posizione: li riordino di conseguenza. Riduce drasticamente
    /// il numero di richieste (una per file invece di una per chunk) e quindi il rischio di rate-limit.
    func embedBatch(_ texts: [String]) async -> [EmbeddingResult?] {
        guard !texts.isEmpty, !apiKey.isEmpty,
              URL(string: "https://api.openai.com/v1/embeddings") != nil else {
            return Array(repeating: nil, count: texts.count)
        }

        // Limita sia il numero di elementi sia la dimensione testuale del payload. Documenti
        // molto grandi non fanno più fallire in blocco tutti i chunk dello stesso file.
        var results: [EmbeddingResult?] = Array(repeating: nil, count: texts.count)
        var start = 0
        while start < texts.count {
            var end = start
            var characters = 0
            while end < texts.count, end - start < 64 {
                let next = texts[end].count
                if end > start, characters + next > 180_000 { break }
                characters += next
                end += 1
            }
            let batch = Array(texts[start..<max(end, start + 1)])
            let partial = await requestBatch(batch)
            for (offset, value) in partial.enumerated() where start + offset < results.count {
                results[start + offset] = value
            }
            start += batch.count
        }
        return results
    }

    private func requestBatch(_ texts: [String]) async -> [EmbeddingResult?] {
        guard let url = URL(string: "https://api.openai.com/v1/embeddings") else {
            return Array(repeating: nil, count: texts.count)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "input": texts])
        request.timeoutInterval = 60

        for attempt in 0..<3 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let dataArray = json["data"] as? [[String: Any]] {
                    var results: [EmbeddingResult?] = Array(repeating: nil, count: texts.count)
                    for item in dataArray {
                        guard let index = item["index"] as? Int, index >= 0, index < texts.count,
                              let array = item["embedding"] as? [Double], !array.isEmpty else { continue }
                        results[index] = EmbeddingResult(providerID: "openai-\(model)", vector: array.map { Float($0) })
                    }
                    return results
                }

                let transient = status == 429 || status == 408 || (500...599).contains(status)
                embeddingLog.error("OpenAI batch HTTP \(status), tentativo \(attempt + 1)")
                if !transient { break }
            } catch {
                embeddingLog.error("OpenAI batch rete: \(error.localizedDescription, privacy: .public)")
            }
            if attempt < 2 {
                try? await Task.sleep(for: .milliseconds(400 * (1 << attempt)))
            }
        }
        return Array(repeating: nil, count: texts.count)
    }
}
