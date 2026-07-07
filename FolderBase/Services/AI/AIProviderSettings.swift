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
        static let provider = "aiEmbeddingProvider"
        static let ollamaBaseURL = "aiOllamaBaseURL"
        static let ollamaModel = "aiOllamaModel"
        static let openAIModel = "aiOpenAIModel"
        static let chatProvider = "aiChatProvider"
        static let ollamaChatModel = "aiOllamaChatModel"
        static let openAIChatModel = "aiOpenAIChatModel"
        static let chatContextChunks = "aiChatContextChunks"
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
