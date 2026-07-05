import Foundation

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
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let array = json["embedding"] as? [Double], !array.isEmpty else { return nil }

        return EmbeddingResult(providerID: "ollama-\(model)", vector: array.map { Float($0) })
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
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]],
              let first = dataArray.first,
              let array = first["embedding"] as? [Double], !array.isEmpty else { return nil }

        return EmbeddingResult(providerID: "openai-\(model)", vector: array.map { Float($0) })
    }
}
