import Foundation
import PDFKit
import Vision
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Risultato dell'estrazione: testo grezzo e se è stato necessario l'OCR.
struct ExtractedText: Sendable {
    let text: String
    let ocrUsed: Bool
}

/// Estrazione del testo dai file, interamente on-device e senza dipendenze esterne.
///
/// Formati gestiti (indicizzazione contenuti):
/// - **testo semplice** (txt/md/csv/tsv/json/xml/codice…): lettura diretta con rilevamento encoding;
/// - **PDF**: layer testo via PDFKit, con fallback OCR pagina-per-pagina se il PDF è scansionato;
/// - **immagini** (png/jpg/heic/tiff…): OCR via Vision;
/// - **Word e affini** (doc/docx/rtf/odt/html): via `textutil` (integrato in macOS);
/// - **PowerPoint** (pptx) e **Excel** (xlsx): unzip del pacchetto OOXML + estrazione testo dagli XML;
/// - **Office legacy** (.xls/.ppt) e **iWork** (.pages/.numbers/.key): best-effort via anteprima QuickLook.
///
/// Nota: per .xls legacy l'anteprima QuickLook espone poco testo (spesso solo i nomi dei fogli).
///
/// Tutte le funzioni sono pensate per l'esecuzione su un thread di background (incluse le
/// chiamate a `textutil`/`unzip` via `Process`; l'app non è sandboxed).
enum TextExtractor {
    /// Caratteri massimi conservati per file (evita di gonfiare il DB con file enormi).
    static let maxCharacters = 200_000
    /// Se il layer testo di un PDF è più corto di così, si assume scansionato e si tenta l'OCR.
    private static let pdfTextThreshold = 16
    /// Pagine massime sottoposte a OCR per un singolo PDF (l'OCR è costoso).
    private static let maxOCRPages = 30
    /// Fattore di rendering delle pagine PDF prima dell'OCR (più alto = più preciso, più lento).
    private static let renderScale: CGFloat = 2.0

    static let recognitionLanguages = ["it-IT", "en-US"]

    /// Dimensione massima per un file di tipo sconosciuto (nessun UTType): oltre questa soglia non
    /// si tenta la lettura come testo, per non caricare in memoria interi binari senza tipo.
    static let unknownTypeMaxBytes = 2_000_000

    /// Estensioni note come NON indicizzabili: media, archivi, immagini disco, binari/eseguibili,
    /// database, font, formati grafici proprietari. Da questi file non si ricava testo utile, quindi
    /// vanno esclusi PRIMA di tentare estrazione/OCR/anteprima (che sarebbero solo lavoro sprecato).
    nonisolated static let nonIndexableExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "webm", "mpg", "mpeg", "wmv", "flv", "3gp", "m2ts", "ts",
        "mp3", "wav", "aac", "flac", "ogg", "oga", "m4a", "aiff", "aif", "wma", "opus", "amr",
        "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "iso", "pkg", "cpgz", "zst", "lz4",
        "app", "exe", "dll", "so", "dylib", "o", "a", "bin", "class", "jar", "wasm", "msi", "deb", "rpm",
        "sqlite", "sqlite3", "db", "db3", "mdb", "accdb", "realm", "pack", "idx",
        "ttf", "otf", "ttc", "woff", "woff2",
        "psd", "ai", "sketch", "fig", "blend", "fbx", "obj", "stl", "3ds", "dwg", "ico", "icns",
        "crdownload", "part", "tmp"
    ]

    /// True se dal file è plausibile estrarre testo (direttamente o via OCR/anteprima). Usato per
    /// filtrare la coda di indicizzazione: evita di tentare l'estrazione su file inutili. Rispecchia
    /// esattamente i formati gestiti da `extractText`.
    nonisolated static func isIndexableCandidate(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if nonIndexableExtensions.contains(ext) { return false }
        if ["eml", "emlx"].contains(ext) { return true }
        if textutilExtensions.contains(ext) { return true }
        if ooxmlPresentationExtensions.contains(ext) || ooxmlSpreadsheetExtensions.contains(ext) { return true }
        if quickLookExtensions.contains(ext) { return true }

        if ext.isEmpty {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return size > 0 && size <= unknownTypeMaxBytes && looksLikeTextFile(url)
        }

        if let type = fileType(for: url) {
            if type.conforms(to: .pdf) || type.conforms(to: .image) { return true }
            if isPlainTextType(type) { return true }
            if isQuickLookDocumentType(type) { return true }
            // Tipo noto ma non testuale (audio/video/archivio/eseguibile…): non indicizzabile.
            return false
        }

        // Tipo sconosciuto (es. .pem, dotfile di configurazione): plausibilmente testo, ma solo se
        // piccolo, per non leggere interi binari privi di tipo.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size > 0 && size <= unknownTypeMaxBytes && looksLikeTextFile(url)
    }

    static func extractText(from url: URL) -> ExtractedText? {
        guard !Task.isCancelled else { return nil }
        let ext = url.pathExtension.lowercased()

        // Email RFC 822 / Apple Mail: sono file testuali MIME. Conservare anche gli header è
        // utile alla ricerca (mittente, destinatari, oggetto, data) oltre al corpo del messaggio.
        if ext == "eml" || ext == "emlx" {
            guard let text = readPlainText(from: url) else { return nil }
            return ExtractedText(text: capped(text), ocrUsed: false)
        }

        // Documenti Office / rich text gestiti per estensione con strumenti nativi macOS
        // (nessuna dipendenza esterna). Tutto eseguibile su thread di background.
        if Self.textutilExtensions.contains(ext) {
            guard let text = extractWithTextutil(url) else { return nil }
            return ExtractedText(text: capped(text), ocrUsed: false)
        }
        if Self.ooxmlPresentationExtensions.contains(ext) {
            guard let text = extractZipXML(url, patterns: ["ppt/slides/slide*.xml", "ppt/notesSlides/notesSlide*.xml"]) else { return nil }
            return ExtractedText(text: capped(text), ocrUsed: false)
        }
        if Self.ooxmlSpreadsheetExtensions.contains(ext) {
            let text = extractZipXML(url, patterns: ["xl/sharedStrings.xml"])
                ?? extractZipXML(url, patterns: ["xl/worksheets/sheet*.xml"])
            guard let text else { return nil }
            return ExtractedText(text: capped(text), ocrUsed: false)
        }

        let type = fileType(for: url)

        if let type {
            if type.conforms(to: .pdf) {
                return extractPDF(from: url)
            }
            if type.conforms(to: .image) {
                guard let text = ocrImage(at: url), !text.isEmpty else { return nil }
                return ExtractedText(text: capped(text), ocrUsed: true)
            }
            if isPlainTextType(type) {
                guard let text = readPlainText(from: url) else { return nil }
                return ExtractedText(text: capped(text), ocrUsed: false)
            }
        }

        // Formati "ricchi" binari o a pacchetto senza estrattore diretto: Office legacy
        // (.xls/.ppt) e iWork (.pages/.numbers/.key Keynote). Si usa l'anteprima generata da
        // QuickLook come sorgente di testo (on-device). NB: .key Keynote qui viene gestito,
        // mentre un .key testuale (es. chiave SSH/PEM) fallisce l'anteprima e ricade sotto.
        if Self.quickLookExtensions.contains(ext) {
            if let result = extractViaQuickLook(url) { return result }
        }

        if let type, isQuickLookDocumentType(type), let result = extractViaQuickLook(url) {
            return result
        }

        // Tipo sconosciuto: ultimo tentativo come testo semplice (es. PEM, file senza tipo noto).
        // Per i tipi noti ma non gestiti si evita di proposito la lettura grezza (darebbe binario).
        if type == nil {
            guard let text = readPlainText(from: url),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ExtractedText(text: capped(text), ocrUsed: false)
        }

        return nil
    }

    /// Estensioni gestite da `textutil` (Word e altri formati rich text/documento).
    private static let textutilExtensions: Set<String> = [
        "doc", "docx", "docm", "dot", "dotx", "dotm", "rtf", "rtfd", "odt",
        "html", "htm", "webarchive", "wordml"
    ]

    private static let ooxmlPresentationExtensions: Set<String> = [
        "pptx", "pptm", "ppsx", "ppsm", "potx", "potm"
    ]

    private static let ooxmlSpreadsheetExtensions: Set<String> = [
        "xlsx", "xlsm", "xltx", "xltm"
    ]

    /// Estensioni gestite come best-effort tramite l'anteprima QuickLook: binari legacy Office
    /// e pacchetti iWork (non hanno un estrattore testuale nativo diretto).
    private static let quickLookExtensions: Set<String> = [
        "xls", "ppt", "pps", "pages", "numbers", "key", "odp", "ods", "msg"
    ]

    /// Controllo conservativo per file senza estensione o con tipo sconosciuto. Evita che plist
    /// binarie, contenuti compilati/cifrati e altri blob piccoli entrino nel totale indicizzabile.
    nonisolated private static func looksLikeTextFile(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), !data.isEmpty else { return false }
        let sample = data.prefix(16_384)
        if sample.starts(with: Data("bplist00".utf8)) { return false }
        if sample.starts(with: [0x7f, 0x45, 0x4c, 0x46]) || sample.starts(with: [0xcf, 0xfa, 0xed, 0xfe]) { return false }
        if let header = String(data: sample.prefix(256), encoding: .utf8),
           header.contains("BEGIN ENCRYPTED PRIVATE KEY") || header.contains("BEGIN PGP MESSAGE")
            || header.contains("age-encryption.org/") { return false }
        if sample.contains(0) { return false }
        let controls = sample.reduce(into: 0) { count, byte in
            if byte < 0x20, byte != 0x09, byte != 0x0a, byte != 0x0d { count += 1 }
        }
        guard Double(controls) / Double(sample.count) < 0.02 else { return false }
        return String(data: sample, encoding: .utf8) != nil
            || String(data: sample, encoding: .isoLatin1) != nil
    }

    // MARK: - Tipo file

    private static func fileType(for url: URL) -> UTType? {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type
        }
        return UTType(filenameExtension: url.pathExtension)
    }

    /// Testo semplice = plain text o testo strutturato (json/xml/csv/codice), ma NON RTF
    /// (che da lettura grezza produrrebbe solo control-word).
    private static func isPlainTextType(_ type: UTType) -> Bool {
        if type.conforms(to: .rtf) { return false }
        return type.conforms(to: .plainText) || type.conforms(to: .sourceCode) || type.conforms(to: .text)
    }

    /// Documenti che macOS sa rappresentare tramite Quick Look ma per cui non abbiamo un
    /// estrattore diretto. I contenuti multimediali, archivi, eseguibili e plist restano esclusi.
    private static func isQuickLookDocumentType(_ type: UTType) -> Bool {
        guard type.conforms(to: .content),
              !type.conforms(to: .audiovisualContent),
              !type.conforms(to: .archive),
              !type.conforms(to: .executable),
              !type.conforms(to: .propertyList) else { return false }
        return true
    }

    // MARK: - Testo semplice

    private static func readPlainText(from url: URL) -> String? {
        guard !Task.isCancelled else { return nil }
        // Carica il file una sola volta: i fallback cambiano soltanto la decodifica del buffer.
        // Questo evita fino a tre letture dal filesystem per i testi non UTF-8.
        guard let data = try? Data(contentsOf: url) else { return nil }

        if let text = String(data: data, encoding: .utf8) {
            return text
        }

        var converted: NSString?
        let detectedEncoding = NSString.stringEncoding(
            for: data,
            encodingOptions: nil,
            convertedString: &converted,
            usedLossyConversion: nil
        )
        if detectedEncoding != 0,
           let text = converted as String? {
            return text
        }

        // Ultimo fallback: latin-1 (non fallisce quasi mai, interpreta byte per byte).
        return String(data: data, encoding: .isoLatin1)
    }

    // MARK: - PDF

    private static func extractPDF(from url: URL) -> ExtractedText? {
        guard let document = PDFDocument(url: url) else { return nil }

        let embedded = document.string ?? ""
        if embedded.trimmingCharacters(in: .whitespacesAndNewlines).count >= pdfTextThreshold {
            return ExtractedText(text: capped(embedded), ocrUsed: false)
        }

        // PDF scansionato (nessun layer testo utile): OCR pagina per pagina.
        var ocrText = ""
        let pageLimit = min(document.pageCount, maxOCRPages)
        for pageIndex in 0..<pageLimit {
            if Task.isCancelled { return nil }
            guard let page = document.page(at: pageIndex),
                  let cgImage = render(page: page) else { continue }
            if let text = ocr(cgImage: cgImage), !text.isEmpty {
                ocrText += text + "\n"
            }
            if ocrText.count >= maxCharacters { break }
        }

        let trimmed = ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : ExtractedText(text: capped(trimmed), ocrUsed: true)
    }

    private static func render(page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(bounds.width * renderScale)
        let height = Int(bounds.height * renderScale)
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: renderScale, y: renderScale)
        context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    // MARK: - Immagini / OCR

    private static func ocrImage(at url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return ocr(cgImage: cgImage)
    }

    private static func ocr(cgImage: CGImage) -> String? {
        guard !Task.isCancelled else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = recognitionLanguages

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        let observations = request.results ?? []
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: - Office / rich text (strumenti nativi macOS)

    /// Word/RTF/ODT/HTML via `/usr/bin/textutil` (integrato in macOS): conversione a testo
    /// semplice con spaziatura corretta. Nessuna dipendenza esterna.
    private static func extractWithTextutil(_ url: URL) -> String? {
        guard let data = runProcess("/usr/bin/textutil", ["-convert", "txt", "-stdout", url.path]) else { return nil }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// PPTX/XLSX (pacchetti ZIP OOXML): estrae le voci XML indicate con `/usr/bin/unzip -p`
    /// e ne rimuove i tag. L'ordine del testo non è garantito, ma per la ricerca conta solo
    /// che tutte le parole siano presenti.
    private static func extractZipXML(_ url: URL, patterns: [String]) -> String? {
        guard let data = runProcess("/usr/bin/unzip", ["-p", url.path] + patterns),
              let xml = String(data: data, encoding: .utf8), !xml.isEmpty else { return nil }
        let text = stripXML(xml)
        return text.isEmpty ? nil : text
    }

    /// Anteprima QuickLook come sorgente di testo per i formati senza estrattore diretto.
    /// Genera l'anteprima in una cartella temporanea (`qlmanage -p`), poi ne estrae il testo:
    /// preferisce `Preview.html`/`.rtf` (via textutil), altrimenti un `Preview.pdf` (via PDFKit,
    /// con OCR). Pulisce sempre la cartella temporanea.
    private static func extractViaQuickLook(_ url: URL) -> ExtractedText? {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("folderbase-ql-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        _ = runProcess("/usr/bin/qlmanage", ["-p", "-o", tempDir.path, url.path], timeout: 25)

        guard let bundle = (try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "qlpreview" }) else { return nil }
        let entries = (try? FileManager.default.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil)) ?? []

        // 1) Sorgente testuale dell'anteprima (contiene il testo vero, non le immagini allegate).
        if let textSource = entries.first(where: {
            let name = $0.lastPathComponent.lowercased()
            return name.hasPrefix("preview") && ["html", "htm", "rtf", "txt"].contains($0.pathExtension.lowercased())
        }), let text = extractWithTextutil(textSource) {
            return ExtractedText(text: capped(text), ocrUsed: false)
        }

        // 2) Anteprima PDF (solo "Preview.pdf": gli Attachment*.pdf sono immagini incorporate).
        if let previewPDF = entries.first(where: { $0.lastPathComponent.lowercased() == "preview.pdf" }) {
            return extractPDF(from: previewPDF)
        }

        return nil
    }

    /// Esegue un processo e ne cattura lo standard output. Legge il pipe PRIMA di
    /// `waitUntilExit` per evitare deadlock quando l'output supera il buffer del pipe.
    /// Un watchdog termina il processo se supera `timeout` (protegge da anteprime bloccate).
    private static func runProcess(_ launchPath: String, _ arguments: [String], timeout: TimeInterval = 20) -> Data? {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        // CRITICO: dare esplicitamente uno stdin valido (/dev/null). Senza questo il figlio eredita
        // il fd 0 del processo GUI, che macOS "protegge" (guarded): NSTask tenta `dup(0)` e l'app
        // crasha con EXC_GUARD (DUP su fd 0) al primo file che richiede QuickLook.
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }

        // La lettura dello stdout è BLOCCANTE: se il figlio (es. qlmanage) si appende senza
        // chiudere lo stdout, `readDataToEndOfFile` non torna mai. Leggo quindi su un thread a
        // parte e attendo con un timeout reale; allo scadere forzo la chiusura con SIGKILL
        // (SIGTERM/`terminate()` da solo può essere ignorato) e sblocco il reader. Così nessun
        // file può bloccare l'indicizzazione all'infinito.
        let handle = pipe.fileHandleForReading
        let box = DataBox()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.data = handle.readDataToEndOfFile()
            semaphore.signal()
        }

        let deadline = Date().addingTimeInterval(timeout)
        var completed = false
        while !completed, !Task.isCancelled, Date() < deadline {
            completed = semaphore.wait(timeout: .now() + 0.1) == .success
        }
        if !completed {
            kill(process.processIdentifier, SIGKILL)   // forza la terminazione
            try? handle.close()                         // sblocca readDataToEndOfFile
            process.waitUntilExit()
            return nil
        }

        // La lettura è terminata prima del timeout: il valore in `box` è sincronizzato dal semaforo.
        process.waitUntilExit()
        return box.data
    }

    /// Contenitore per passare in sicurezza i dati letti dal thread di lettura (la sincronizzazione
    /// avviene tramite il semaforo: si legge `data` solo dopo `wait` riuscita).
    private final class DataBox: @unchecked Sendable {
        var data: Data?
    }

    /// Rimuove i tag XML (sostituiti da spazio), decodifica le entità comuni e compatta gli
    /// spazi. Sufficiente per estrarre il testo cercabile da OOXML.
    private static func stripXML(_ xml: String) -> String {
        var text = xml.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Utility

    private static func capped(_ text: String) -> String {
        text.count <= maxCharacters ? text : String(text.prefix(maxCharacters))
    }
}
