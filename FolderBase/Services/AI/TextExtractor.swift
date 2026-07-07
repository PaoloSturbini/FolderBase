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

    static func extractText(from url: URL) -> ExtractedText? {
        let ext = url.pathExtension.lowercased()

        // Documenti Office / rich text gestiti per estensione con strumenti nativi macOS
        // (nessuna dipendenza esterna). Tutto eseguibile su thread di background.
        if Self.textutilExtensions.contains(ext) {
            guard let text = extractWithTextutil(url) else { return nil }
            return ExtractedText(text: capped(text), ocrUsed: false)
        }
        if ext == "pptx" {
            guard let text = extractZipXML(url, patterns: ["ppt/slides/slide*.xml", "ppt/notesSlides/notesSlide*.xml"]) else { return nil }
            return ExtractedText(text: capped(text), ocrUsed: false)
        }
        if ext == "xlsx" {
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
        "doc", "docx", "rtf", "rtfd", "odt", "html", "htm", "webarchive", "wordml"
    ]

    /// Estensioni gestite come best-effort tramite l'anteprima QuickLook: binari legacy Office
    /// e pacchetti iWork (non hanno un estrattore testuale nativo diretto).
    private static let quickLookExtensions: Set<String> = [
        "xls", "ppt", "pps", "pages", "numbers", "key", "odp", "ods"
    ]

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

    // MARK: - Testo semplice

    private static func readPlainText(from url: URL) -> String? {
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        var usedEncoding: String.Encoding = .utf8
        if let text = try? String(contentsOf: url, usedEncoding: &usedEncoding) {
            return text
        }
        // Ultimo fallback: latin-1 (non fallisce quasi mai, interpreta byte per byte).
        if let data = try? Data(contentsOf: url) {
            return String(data: data, encoding: .isoLatin1)
        }
        return nil
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
        // crasha con EXC_GUARD (DUP su fd 0) al primo file che richiede QuickLook → l'indicizzazione
        // si "staccava" dopo pochi file.
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return data
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
