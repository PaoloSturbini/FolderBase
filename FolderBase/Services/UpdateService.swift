import Foundation

/// Esito del controllo di una nuova versione su GitHub.
enum UpdateCheckResult {
    /// L'app installata è già l'ultima disponibile. `current` è la versione locale.
    case upToDate(current: String)
    /// È disponibile una versione più recente. `latest` è il tag della release,
    /// `releaseURL` la pagina della release, `downloadURL` il .dmg allegato (se presente).
    case updateAvailable(latest: String, current: String, releaseURL: URL, downloadURL: URL?)
    /// Il controllo non è riuscito (rete assente, risposta non valida, ecc.).
    case failed(String)
}

/// Controlla se esiste una versione più recente di FolderBase pubblicata su GitHub.
///
/// I DMG versionati NON stanno nella cartella `dist/` del repo (è in `.gitignore`): vengono
/// pubblicati come *release* con il .dmg allegato. La fonte autorevole è quindi la
/// GitHub Releases API (`/releases/latest`), che restituisce il tag dell'ultima release e
/// l'URL diretto del .dmg da scaricare.
enum UpdateService {
    /// Repository pubblico di FolderBase.
    static let repository = "PaoloSturbini/FolderBase"

    /// Versione dell'app attualmente in esecuzione (CFBundleShortVersionString).
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Interroga GitHub e restituisce l'esito sul main thread.
    static func checkForUpdate(completion: @escaping (UpdateCheckResult) -> Void) {
        let deliver: (UpdateCheckResult) -> Void = { result in
            DispatchQueue.main.async { completion(result) }
        }

        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            deliver(.failed("URL non valido"))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                deliver(.failed(error.localizedDescription))
                return
            }

            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                deliver(.failed("Risposta non valida da GitHub"))
                return
            }

            let latestComponents = versionComponents(tag)
            let currentComponents = versionComponents(currentVersion)

            let releaseURL = (json["html_url"] as? String).flatMap(URL.init(string:))
                ?? URL(string: "https://github.com/\(repository)/releases/latest")!

            var downloadURL: URL?
            if let assets = json["assets"] as? [[String: Any]] {
                for asset in assets {
                    guard let name = asset["name"] as? String,
                          name.lowercased().hasSuffix(".dmg"),
                          let urlString = asset["browser_download_url"] as? String,
                          let assetURL = URL(string: urlString) else { continue }
                    downloadURL = assetURL
                    break
                }
            }

            if compare(latestComponents, currentComponents) == .orderedDescending {
                deliver(.updateAvailable(latest: tag, current: currentVersion, releaseURL: releaseURL, downloadURL: downloadURL))
            } else {
                deliver(.upToDate(current: currentVersion))
            }
        }.resume()
    }

    /// Trasforma "v1.2.10" → [1, 2, 10]. Ignora il prefisso "v" e caratteri non numerici.
    private static func versionComponents(_ version: String) -> [Int] {
        version
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            .split(separator: ".")
            .map { component in
                Int(component.prefix { $0.isNumber }) ?? 0
            }
    }

    /// Confronto numerico componente per componente (semantico, non lessicografico).
    private static func compare(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
        }
        return .orderedSame
    }
}
