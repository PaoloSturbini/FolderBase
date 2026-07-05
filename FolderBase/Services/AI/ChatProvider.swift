import Foundation

/// Astrae un LLM di chat in streaming (token-by-token). Implementazioni: Ollama (locale) e
/// OpenAI (cloud BYOK). Vedi docs/AI-Indexing-Study.md (Fase 3, RAG).
protocol ChatProvider: Sendable {
    /// Genera la risposta in streaming a partire da un prompt di sistema e uno utente.
    func stream(system: String, user: String) -> AsyncThrowingStream<String, Error>
}

enum ChatProviderError: Error {
    case badResponse
    case invalidURL
}

/// Chat via endpoint locale Ollama (`POST /api/chat`, stream NDJSON). Privato e offline.
struct OllamaChatProvider: ChatProvider {
    let baseURL: String
    let model: String

    func stream(system: String, user: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
                    guard let url = URL(string: base + "/api/chat") else { throw ChatProviderError.invalidURL }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    let body: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "messages": [
                            ["role": "system", "content": system],
                            ["role": "user", "content": user]
                        ]
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ChatProviderError.badResponse }

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard let data = line.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let message = json["message"] as? [String: Any],
                           let content = message["content"] as? String, !content.isEmpty {
                            continuation.yield(content)
                        }
                        if json["done"] as? Bool == true { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Chat via OpenAI (`POST /v1/chat/completions`, stream SSE). ATTENZIONE: il contesto (estratti
/// dei file) viene inviato ai server OpenAI.
struct OpenAIChatProvider: ChatProvider {
    let apiKey: String
    let model: String

    func stream(system: String, user: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else { throw ChatProviderError.invalidURL }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    let body: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "messages": [
                            ["role": "system", "content": system],
                            ["role": "user", "content": user]
                        ]
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ChatProviderError.badResponse }

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let first = choices.first,
                              let delta = first["delta"] as? [String: Any],
                              let content = delta["content"] as? String, !content.isEmpty else { continue }
                        continuation.yield(content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
