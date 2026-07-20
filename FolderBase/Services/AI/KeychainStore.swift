import Foundation
import Security

/// Salvataggio sicuro di segreti (es. chiave API BYOK) nel Portachiavi macOS.
/// Non usa mai `UserDefaults`/file in chiaro per i segreti.
enum KeychainStore {
    private static let service = "com.paolosturbini.folderbase"

    /// Cache in memoria dei segreti già letti: il Portachiavi viene interrogato UNA SOLA VOLTA per
    /// account per avvio dell'app. Senza cache ogni `EmbeddingEngine.active()` — invocato a ogni
    /// ricerca, domanda in chat e per l'indicizzazione — rileggerebbe la chiave, e con l'app
    /// firmata ad-hoc macOS mostra il prompt del Portachiavi a ogni lettura, bloccando
    /// l'indicizzazione ogni pochi file. Valore `nil` in cache = assenza nota (evita riletture).
    private static var cache: [String: String?] = [:]
    private static let cacheLock = NSLock()

    private static func cachedValue(for account: String) -> (hit: Bool, value: String?) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let entry = cache[account] { return (true, entry) }
        return (false, nil)
    }

    private static func setCache(_ value: String?, for account: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cache[account] = value
    }

    static func save(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // Rimuove l'eventuale valore precedente, poi inserisce quello nuovo.
        SecItemDelete(query as CFDictionary)

        if value.isEmpty {
            setCache(nil, for: account)
            if account == AIProviderSettings.openAIKeyAccount {
                UserDefaults.standard.set(false, forKey: AIProviderSettings.Keys.hasOpenAIKey)
            }
            return
        }

        var attributes = query
        attributes[kSecValueData as String] = data
        // Disponibile dopo il primo sblocco del Mac e vincolata a questo dispositivo. Non viene
        // sincronizzata su iCloud e non richiede un'autenticazione interattiva a ogni lettura.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
        // Aggiorna la cache col valore salvato: nessuna rilettura dal Portachiavi.
        setCache(value, for: account)
        if account == AIProviderSettings.openAIKeyAccount {
            UserDefaults.standard.set(true, forKey: AIProviderSettings.Keys.hasOpenAIKey)
        }
    }

    static func load(account: String) -> String? {
        let cached = cachedValue(for: account)
        if cached.hit { return cached.value }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let value = (status == errSecSuccess)
            ? (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
            : nil
        // Memorizza l'esito (valore o assenza) così il Portachiavi non viene più interrogato.
        setCache(value, for: account)
        if account == AIProviderSettings.openAIKeyAccount, value?.isEmpty == false {
            UserDefaults.standard.set(true, forKey: AIProviderSettings.Keys.hasOpenAIKey)
        }
        return value
    }

    static func exists(account: String) -> Bool {
        (load(account: account)?.isEmpty == false)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        setCache(nil, for: account)
        if account == AIProviderSettings.openAIKeyAccount {
            UserDefaults.standard.set(false, forKey: AIProviderSettings.Keys.hasOpenAIKey)
        }
    }
}
