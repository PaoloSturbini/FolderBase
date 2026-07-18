import Foundation
import SwiftUI

/// Struttura intermedia, piccola e testabile, usata per trasformare il Markdown delle risposte
/// in viste SwiftUI native. Conserva il testo inline originale: `AttributedString` si occupa poi
/// di enfasi, grassetto, codice inline e link senza introdurre una WebView o dipendenze esterne.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case unorderedList([String])
    case orderedList(start: Int, items: [String])
    case quote(String)
    case code(language: String?, text: String)
    case table(headers: [String], rows: [[String]])
    case divider
}

enum MarkdownDocumentParser {
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [MarkdownBlock] = []
        var paragraphLines: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            let text = joinedParagraph(paragraphLines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraphLines.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let fence = fenceInfo(trimmed) {
                flushParagraph()
                var codeLines: [String] = []
                index += 1
                while index < lines.count {
                    let candidate = lines[index]
                    if candidate.trimmingCharacters(in: .whitespaces).hasPrefix(fence.marker) {
                        index += 1
                        break
                    }
                    codeLines.append(candidate)
                    index += 1
                }
                blocks.append(.code(language: fence.language, text: codeLines.joined(separator: "\n")))
                continue
            }

            if let heading = headingInfo(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if isDivider(trimmed) {
                flushParagraph()
                blocks.append(.divider)
                index += 1
                continue
            }

            if isTableStart(lines: lines, index: index) {
                flushParagraph()
                let headers = tableCells(lines[index])
                var rows: [[String]] = []
                index += 2 // salta intestazione e riga di separazione Markdown
                while index < lines.count {
                    let row = lines[index]
                    guard !row.trimmingCharacters(in: .whitespaces).isEmpty, row.contains("|") else { break }
                    rows.append(tableCells(row))
                    index += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }

            if unorderedItem(trimmed) != nil {
                flushParagraph()
                var items: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard let item = unorderedItem(candidate) else { break }
                    items.append(item)
                    index += 1
                }
                blocks.append(.unorderedList(items))
                continue
            }

            if let firstItem = orderedItem(trimmed) {
                flushParagraph()
                var items: [String] = []
                let start = firstItem.ordinal
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard let item = orderedItem(candidate) else { break }
                    items.append(item.text)
                    index += 1
                }
                blocks.append(.orderedList(start: start, items: items))
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoteLines: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    quoteLines.append(String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(joinedParagraph(quoteLines)))
                continue
            }

            paragraphLines.append(line)
            index += 1
        }

        flushParagraph()
        return blocks
    }

    static func inlineAttributedString(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }

    private static func joinedParagraph(_ lines: [String]) -> String {
        var result = ""
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if result.isEmpty {
                result = trimmed
            } else if result.hasSuffix("  ") {
                result.removeLast(2)
                result += "\n" + trimmed
            } else {
                result += " " + trimmed
            }
        }
        return result
    }

    private static func fenceInfo(_ line: String) -> (marker: String, language: String?)? {
        let marker: String
        if line.hasPrefix("```") {
            marker = "```"
        } else if line.hasPrefix("~~~") {
            marker = "~~~"
        } else {
            return nil
        }
        let hint = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        return (marker, hint.isEmpty ? nil : hint)
    }

    private static func headingInfo(_ line: String) -> (level: Int, text: String)? {
        let level = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level), line.count > level else { return nil }
        let boundary = line.index(line.startIndex, offsetBy: level)
        guard line[boundary].isWhitespace else { return nil }
        return (level, String(line[boundary...]).trimmingCharacters(in: .whitespaces))
    }

    private static func unorderedItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func orderedItem(_ line: String) -> (ordinal: Int, text: String)? {
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, let ordinal = Int(digits) else { return nil }
        let remainder = line.dropFirst(digits.count)
        guard remainder.count >= 2,
              remainder.first == "." || remainder.first == ")",
              remainder.dropFirst().first?.isWhitespace == true else { return nil }
        return (ordinal, String(remainder.dropFirst(2)).trimmingCharacters(in: .whitespaces))
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first, ["-", "*", "_"].contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func isTableStart(lines: [String], index: Int) -> Bool {
        guard index + 1 < lines.count, lines[index].contains("|") else { return false }
        let separators = tableCells(lines[index + 1])
        guard !separators.isEmpty else { return false }
        return separators.allSatisfy { cell in
            let compact = cell.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            return compact.count >= 3 && compact.allSatisfy { $0 == "-" }
        }
    }

    private static func tableCells(_ line: String) -> [String] {
        var content = line.trimmingCharacters(in: .whitespaces)
        if content.hasPrefix("|") { content.removeFirst() }
        if content.hasSuffix("|") { content.removeLast() }
        return content.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// Rendering Markdown nativo per le risposte dell'assistente.
struct MarkdownMessageView: View {
    let markdown: String

    private var blocks: [MarkdownBlock] {
        MarkdownDocumentParser.parse(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
        .tint(.accentColor)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text)
                .font(headingFont(level))
                .fontWeight(level <= 2 ? .bold : .semibold)
                .padding(.top, level <= 2 ? 2 : 0)

        case .paragraph(let text):
            inlineText(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").fontWeight(.semibold)
                        inlineText(item).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.leading, 4)

        case .orderedList(let start, let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(start + offset).")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        inlineText(item).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.leading, 4)

        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(width: 3)
                inlineText(text)
                    .foregroundStyle(.secondary)
                    .italic()
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .code(let language, let text):
            VStack(alignment: .leading, spacing: 6) {
                if let language {
                    Text(language.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    Text(verbatim: text)
                        .font(.system(.callout, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: false)
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
            }

        case .table(let headers, let rows):
            tableView(headers: headers, rows: rows)

        case .divider:
            Divider()
        }
    }

    private func inlineText(_ source: String) -> Text {
        Text(MarkdownDocumentParser.inlineAttributedString(source))
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2
        case 2: return .title3
        case 3: return .headline
        default: return .subheadline
        }
    }

    private func normalized(_ cells: [String], count: Int) -> [String] {
        if cells.count >= count { return Array(cells.prefix(count)) }
        return cells + Array(repeating: "", count: count - cells.count)
    }

    @ViewBuilder
    private func tableView(headers: [String], rows: [[String]]) -> some View {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        if columnCount > 0 {
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(Array(normalized(headers, count: columnCount).enumerated()), id: \.offset) { _, cell in
                            inlineText(cell)
                                .font(.caption.weight(.semibold))
                                .padding(7)
                                .frame(minWidth: 96, maxWidth: 220, alignment: .leading)
                                .background(Color.accentColor.opacity(0.09))
                        }
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                        GridRow {
                            ForEach(Array(normalized(row, count: columnCount).enumerated()), id: \.offset) { _, cell in
                                inlineText(cell)
                                    .font(.caption)
                                    .padding(7)
                                    .frame(minWidth: 96, maxWidth: 220, alignment: .leading)
                                    .background(rowIndex.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.035))
                            }
                        }
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
                }
            }
        }
    }
}
