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

/// Chiavi di persistenza (UserDefaults per le impostazioni non segrete, Portachiavi per la chiave).
enum AIProviderSettings {
    enum Keys {
        static let provider = "aiEmbeddingProvider"
        static let ollamaBaseURL = "aiOllamaBaseURL"
        static let ollamaModel = "aiOllamaModel"
        static let openAIModel = "aiOpenAIModel"
    }
    static let openAIKeyAccount = "openai-api-key"

    static let defaultOllamaBaseURL = "http://localhost:11434"
    static let defaultOllamaModel = "nomic-embed-text"
    static let defaultOpenAIModel = "text-embedding-3-small"

    static var provider: AIEmbeddingProvider {
        AIEmbeddingProvider(rawValue: UserDefaults.standard.string(forKey: Keys.provider) ?? "") ?? .apple
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
