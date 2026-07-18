import Foundation

/// Provider di embedding selezionabile dall'utente.
enum AIEmbeddingProvider: String, CaseIterable, Identifiable {
    case apple    // on-device, NLEmbedding — default, privato e gratuito
    case ollama   // endpoint locale (Ollama / LM Studio)
    case openai   // cloud BYOK (chiave nel Portachiavi)

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: return L("ai.provider.apple")
        case .ollama: return L("ai.provider.ollama")
        case .openai: return L("ai.provider.openai")
        }
    }
}

/// Provider per la chat (RAG). Nessun motore chat on-device su macOS 14, quindi serve un
/// endpoint locale (Ollama) o cloud (OpenAI).
enum AIChatProvider: String, CaseIterable, Identifiable {
    case none
    case ollama
    case openai

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return L("ai.chat.none")
        case .ollama: return L("ai.provider.ollama")
        case .openai: return L("ai.provider.openai")
        }
    }
}

/// Chiavi di persistenza (UserDefaults per le impostazioni non segrete, Portachiavi per la chiave).
enum AIProviderSettings {
    enum Keys {
        /// Interruttore generale dell'intelligenza artificiale (chat + ricerca per contenuto +
        /// indicizzazione). Quando è false l'app resta un file manager "classico": niente icone
        /// chat e ricerca limitata al solo nome. Default: attiva.
        static let enabled = "aiEnabled"
        static let provider = "aiEmbeddingProvider"
        static let ollamaBaseURL = "aiOllamaBaseURL"
        static let ollamaModel = "aiOllamaModel"
        static let openAIModel = "aiOpenAIModel"
        static let chatProvider = "aiChatProvider"
        static let ollamaChatModel = "aiOllamaChatModel"
        static let openAIChatModel = "aiOpenAIChatModel"
        static let chatContextChunks = "aiChatContextChunks"
        static let excludedSourcePaths = AIExclusionPolicy.storageKey
    }
    static let openAIKeyAccount = "openai-api-key"

    /// Numero di frammenti (chunk) di contesto recuperati per ogni domanda alla chat. Più alto =
    /// più fonti potenziali e risposte più complete, ma prompt più lungo (rischio di sforare la
    /// finestra dei modelli piccoli). Limitato tra 1 e 40; default 12.
    static let defaultChatContextChunks = 12
    static var chatContextChunks: Int {
        let value = UserDefaults.standard.integer(forKey: Keys.chatContextChunks)
        guard value > 0 else { return defaultChatContextChunks }
        return min(max(value, 1), 40)
    }

    static let defaultOllamaBaseURL = "http://localhost:11434"
    static let defaultOllamaModel = "nomic-embed-text"
    static let defaultOpenAIModel = "text-embedding-3-small"
    static let defaultOllamaChatModel = "llama3.1"
    static let defaultOpenAIChatModel = "gpt-4o-mini"

    static var provider: AIEmbeddingProvider {
        // Default: Ollama (qualità semantica nettamente migliore dell'on-device Apple, richiesta
        // dalla ricerca ibrida). Se Ollama non è raggiungibile la ricerca ripiega comunque su FTS
        // e l'utente può scegliere Apple/OpenAI dalla Configurazione. Vedi docs/AI-Indexing-Study.md.
        AIEmbeddingProvider(rawValue: UserDefaults.standard.string(forKey: Keys.provider) ?? "") ?? .ollama
    }
    static var ollamaBaseURL: String {
        let value = UserDefaults.standard.string(forKey: Keys.ollamaBaseURL) ?? ""
        return value.isEmpty ? defaultOllamaBaseURL : value
    }
    static var ollamaModel: String {
        let value = UserDefaults.standard.string(forKey: Keys.ollamaModel) ?? ""
        return value.isEmpty ? defaultOllamaModel : value
    }
    static var openAIModel: String {
        let value = UserDefaults.standard.string(forKey: Keys.openAIModel) ?? ""
        return value.isEmpty ? defaultOpenAIModel : value
    }
    static var chatProvider: AIChatProvider {
        AIChatProvider(rawValue: UserDefaults.standard.string(forKey: Keys.chatProvider) ?? "") ?? .none
    }
    static var ollamaChatModel: String {
        let value = UserDefaults.standard.string(forKey: Keys.ollamaChatModel) ?? ""
        return value.isEmpty ? defaultOllamaChatModel : value
    }
    static var openAIChatModel: String {
        let value = UserDefaults.standard.string(forKey: Keys.openAIChatModel) ?? ""
        return value.isEmpty ? defaultOpenAIChatModel : value
    }
}

/// Risolve l'embedder attivo in base alle impostazioni correnti. Con OpenAI senza chiave o
/// configurazione incompleta, ripiega sull'embedder on-device Apple (così la ricerca funziona
/// sempre). Vedi docs/AI-Indexing-Study.md.
enum EmbeddingEngine {
    static func active() -> TextEmbedder {
        switch AIProviderSettings.provider {
        case .apple:
            return AppleNLEmbedder.shared
        case .ollama:
            return OllamaEmbedder(baseURL: AIProviderSettings.ollamaBaseURL, model: AIProviderSettings.ollamaModel)
        case .openai:
            guard let key = KeychainStore.load(account: AIProviderSettings.openAIKeyAccount), !key.isEmpty else {
                return AppleNLEmbedder.shared
            }
            return OpenAIEmbedder(apiKey: key, model: AIProviderSettings.openAIModel)
        }
    }
}

/// Esito del controllo di salute del motore di embedding attivo. Serve a distinguere — quando
/// l'embedding di alcuni file fallisce — un problema del MOTORE (servizio spento, modello
/// mancante, chiave non valida, rete assente) da un problema dei singoli FILE.
enum EngineHealth: Equatable, Sendable {
    case ok
    case unreachable(detail: String)
}

extension EmbeddingEngine {
    /// Verifica se il motore ATTIVO è raggiungibile e configurato correttamente.
    /// Chiamata a fine indicizzazione solo se ci sono stati fallimenti (una richiesta leggera).
    static func healthCheck() async -> EngineHealth {
        switch AIProviderSettings.provider {
        case .apple:
            return appleHealth()
        case .ollama:
            return await ollamaHealth(baseURL: AIProviderSettings.ollamaBaseURL, model: AIProviderSettings.ollamaModel)
        case .openai:
            // Stessa logica di fallback di `active()`: senza chiave si usa l'embedder Apple.
            guard let key = KeychainStore.load(account: AIProviderSettings.openAIKeyAccount), !key.isEmpty else {
                return appleHealth()
            }
            return await openAIHealth(apiKey: key)
        }
    }

    private static func appleHealth() -> EngineHealth {
        AppleNLEmbedder.availabilityProblem().map { .unreachable(detail: $0) } ?? .ok
    }

    /// Ollama: `GET /api/tags` (istantanea, nessun costo). Distingue servizio spento,
    /// errore HTTP e modello di embedding non installato.
    private static func ollamaHealth(baseURL: String, model: String) async -> EngineHealth {
        let base = baseURL.trimmingCharacters(in: .whitespaces).hasSuffix("/")
            ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: base + "/api/tags") else {
            return .unreachable(detail: "\(L("engine.health.badURL")) \(baseURL)")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return .unreachable(detail: "\(L("engine.health.ollamaDown")) \(base)")
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return .unreachable(detail: "\(L("engine.health.http")) \(status) (\(base))")
        }
        // Il servizio risponde: controlla che il modello di embedding sia installato.
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let models = json["models"] as? [[String: Any]] {
            let names = models.compactMap { $0["name"] as? String }
            let found = names.contains { $0 == model || $0.hasPrefix(model + ":") }
            if !found {
                return .unreachable(detail: "\(L("engine.health.modelMissing")) \u{201C}\(model)\u{201D} — ollama pull \(model)")
            }
        }
        return .ok
    }

    /// OpenAI: `GET /v1/models` (gratuita). Distingue rete assente da chiave non valida.
    private static func openAIHealth(apiKey: String) async -> EngineHealth {
        guard let url = URL(string: "https://api.openai.com/v1/models") else { return .ok }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        guard let (_, response) = try? await URLSession.shared.data(for: request) else {
            return .unreachable(detail: L("engine.health.openaiDown"))
        }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return .ok
        case 401: return .unreachable(detail: L("engine.health.openaiKey"))
        case let status: return .unreachable(detail: "\(L("engine.health.http")) \(status) (api.openai.com)")
        }
    }
}

/// Risolve il provider di chat attivo (nil se non configurato o senza chiave).
enum ChatEngine {
    static func active() -> ChatProvider? {
        switch AIProviderSettings.chatProvider {
        case .none:
            return nil
        case .ollama:
            return OllamaChatProvider(baseURL: AIProviderSettings.ollamaBaseURL, model: AIProviderSettings.ollamaChatModel)
        case .openai:
            guard let key = KeychainStore.load(account: AIProviderSettings.openAIKeyAccount), !key.isEmpty else { return nil }
            return OpenAIChatProvider(apiKey: key, model: AIProviderSettings.openAIChatModel)
        }
    }
}
