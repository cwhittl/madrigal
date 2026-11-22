import SwiftUI
import os
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Markdown rendering without a dependency. Block structure (headings,
/// lists, quotes, tables, rules, fenced code) is parsed here; inline styling
/// within each block is left to AttributedString. Deliberately not a syntax
/// highlighter - see spec section 8.2.
struct MarkdownText: View {
    let content: String
    /// Prose fonts come from the platform's text styles, so read the size
    /// here to rebuild them when it changes.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let _ = dynamicTypeSize
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(Self.segments(of: Self.blocks(of: content)).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let blocks):
                    SelectableText(text: Self.attributedProse(blocks))
                case .code(let language, let code):
                    CodeBlockView(language: language, code: code)
                case .table(let header, let rows):
                    table(header: header, rows: rows)
                }
            }
        }
    }

    /// Runs of prose share one text view, so a selection can cross them.
    /// Code and tables keep their own views and break the run.
    enum Segment: Equatable {
        case prose([Block])
        case code(language: String, code: String)
        case table(header: [String], rows: [[String]])
    }

    nonisolated static func segments(of blocks: [Block]) -> [Segment] {
        var segments: [Segment] = []
        var prose: [Block] = []
        func flush() {
            if !prose.isEmpty { segments.append(.prose(prose)) }
            prose = []
        }
        for block in blocks {
            switch block {
            case .code(let language, let code):
                flush()
                segments.append(.code(language: language, code: code))
            case .table(let header, let rows):
                flush()
                segments.append(.table(header: header, rows: rows))
            default:
                prose.append(block)
            }
        }
        flush()
        return segments
    }

    private func table(header: [String], rows: [[String]]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(Self.attributed(cell)).bold()
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(Self.attributed(cell))
                        }
                    }
                }
            }
            .padding(10)
        }
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
    }

    nonisolated static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    // MARK: - Selectable text

    /// Prose blocks as one styled string for a native text view, where a
    /// selection can cross blocks. No markdown syntax survives, so a copy
    /// pastes as rich text in Mail or Notes and as clean text elsewhere.
    /// Blocks are single paragraphs (lists one per item) separated by
    /// `paragraphSpacing`; line breaks inside a block are U+2028.
    nonisolated static func attributedProse(_ blocks: [Block]) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            if index > 0 { output.append(separator(after: output)) }
            let start = output.length
            output.append(ProseBlockCache.text(for: block) { proseBlock(block) })
            if output.length > start {
                setSpacing(SelectableStyle.blockSpacing, ofLastParagraphIn: output)
            }
        }
        setSpacing(0, ofLastParagraphIn: output)
        return output
    }

    nonisolated private static func proseBlock(_ block: Block) -> NSAttributedString {
        switch block {
        case .heading(let level, let text):
            let heading = NSMutableAttributedString(attributedString: inline(text, font: SelectableStyle.headingFont(level)))
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = level <= 2 ? 4 : 0
            heading.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: heading.length))
            return heading
        case .paragraph(let text):
            let paragraph = NSMutableAttributedString(attributedString: inline(text))
            paragraph.addAttribute(.paragraphStyle, value: NSParagraphStyle(), range: NSRange(location: 0, length: paragraph.length))
            return paragraph
        case .list(let items):
            let list = NSMutableAttributedString()
            for (index, item) in items.enumerated() {
                if index > 0 { list.append(separator(after: list)) }
                let marker: String
                switch item.marker {
                case .bullet: marker = item.depth == 0 ? "\u{2022}" : (item.depth == 1 ? "\u{25E6}" : "\u{25AA}")
                case .ordered(let label): marker = label
                case .task(let checked): marker = checked ? "\u{2611}" : "\u{2610}"
                }
                var markerAttributes = SelectableStyle.base
                markerAttributes[.foregroundColor] = SelectableStyle.secondaryColor
                let line = NSMutableAttributedString(string: marker, attributes: markerAttributes)
                line.append(NSAttributedString(string: "\t", attributes: SelectableStyle.base))
                line.append(inline(item.text))
                let style = NSMutableParagraphStyle()
                let indent = CGFloat(item.depth) * 18
                style.firstLineHeadIndent = indent
                style.headIndent = indent + 24
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent + 24)]
                style.paragraphSpacing = 4
                line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
                list.append(line)
            }
            return list
        case .quote(let text):
            let quote = NSMutableAttributedString(attributedString: attributedProse(blocks(of: text)))
            let full = NSRange(location: 0, length: quote.length)
            quote.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
                let style = ((value as? NSParagraphStyle) ?? NSParagraphStyle()).mutableCopy() as! NSMutableParagraphStyle
                style.firstLineHeadIndent += SelectableStyle.quoteIndent
                style.headIndent += SelectableStyle.quoteIndent
                style.tabStops = style.tabStops.map {
                    NSTextTab(textAlignment: $0.alignment, location: $0.location + SelectableStyle.quoteIndent)
                }
                quote.addAttribute(.paragraphStyle, value: style, range: range)
            }
            quote.addAttribute(.foregroundColor, value: SelectableStyle.secondaryColor, range: full)
            return quote
        case .code(_, let code):
            // Not prose, but rendered sensibly if one turns up here (as in a quote).
            var attributes = SelectableStyle.base
            attributes[.font] = SelectableStyle.codeFont
            return NSAttributedString(string: code.replacingOccurrences(of: "\n", with: "\u{2028}"), attributes: attributes)
        case .table(let header, let rows):
            let lines = ([header] + rows).map { $0.joined(separator: "\t") }
            return inline(lines.joined(separator: "\n"))
        case .rule:
            // Joined by newlines either side, so this leaves an empty line.
            return NSAttributedString()
        }
    }

    /// A paragraph break styled like the paragraph it ends, so that style
    /// covers the whole paragraph. A rule's empty line is then spaced like
    /// the block before it.
    nonisolated private static func separator(after text: NSAttributedString) -> NSAttributedString {
        guard text.length > 0 else { return NSAttributedString(string: "\n", attributes: SelectableStyle.base) }
        var attributes = text.attributes(at: text.length - 1, effectiveRange: nil)
        attributes[.link] = nil
        return NSAttributedString(string: "\n", attributes: attributes)
    }

    /// Sets `paragraphSpacing` on the final paragraph, keeping its other style.
    nonisolated private static func setSpacing(_ spacing: CGFloat, ofLastParagraphIn text: NSMutableAttributedString) {
        guard text.length > 0 else { return }
        let string = text.string as NSString
        let lastBreak = string.rangeOfCharacter(from: CharacterSet(charactersIn: "\n"), options: .backwards)
        let start = lastBreak.location == NSNotFound ? 0 : lastBreak.location + 1
        guard start < text.length else { return }
        let range = NSRange(location: start, length: text.length - start)
        let current = text.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle
        let style = (current ?? NSParagraphStyle()).mutableCopy() as! NSMutableParagraphStyle
        style.paragraphSpacing = spacing
        text.addAttribute(.paragraphStyle, value: style, range: range)
    }

    /// Inline markdown mapped onto platform fonts: strong is bold, emphasis
    /// italic, code monospaced. `font` replaces the body font, as for headings.
    /// Line breaks become U+2028, so they don't start a new paragraph.
    nonisolated private static func inline(_ text: String, font: SelectableStyle.PlatformFont? = nil) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let attributed = attributed(text)
        let baseFont = font ?? SelectableStyle.bodyFont
        for run in attributed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var runFont = baseFont
            if intent.contains(.code) {
                runFont = .monospacedSystemFont(ofSize: baseFont.pointSize * 0.94, weight: .regular)
            } else if intent.contains(.stronglyEmphasized) || intent.contains(.emphasized) {
                runFont = baseFont.withTraits(
                    bold: intent.contains(.stronglyEmphasized),
                    italic: intent.contains(.emphasized)
                )
            }
            var attributes = SelectableStyle.base
            attributes[.font] = runFont
            // Model output can carry links from pages it read; only web and
            // mail links stay tappable.
            if let link = run.link, link.isSafeToOpen { attributes[.link] = link }
            if intent.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            let string = String(attributed[run.range].characters).replacingOccurrences(of: "\n", with: "\u{2028}")
            output.append(NSAttributedString(string: string, attributes: attributes))
        }
        return output
    }

    // MARK: - Parsing

    enum Block: Hashable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case list([ListItem])
        case quote(String)
        case code(language: String, code: String)
        case table(header: [String], rows: [[String]])
        case rule
    }

    struct ListItem: Hashable {
        enum Marker: Hashable {
            case bullet
            case ordered(String)   // "1." as written
            case task(checked: Bool)
        }
        var marker: Marker
        var depth: Int
        var text: String
    }

    /// Line-based block parser covering what models actually emit. Pure and
    /// nonisolated, unlike the view around it. Lenient
    /// by design: it runs on every streamed update, so unterminated fences
    /// and half-written tables must render as something sensible.
    nonisolated static func blocks(of content: String) -> [Block] {
        let lines = content.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [Block] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var items: [ListItem] = []
        var listIndents: [Int] = []

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph = []
        }
        func flushQuote() {
            let text = quote.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.quote(text)) }
            quote = []
        }
        func flushList() {
            if !items.isEmpty { blocks.append(.list(items)) }
            items = []
            listIndents = []
        }
        func flushAll() {
            flushParagraph()
            flushQuote()
            flushList()
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushAll()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                var closed = false
                while index < lines.count {
                    if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                        closed = true
                        index += 1
                        break
                    }
                    code.append(lines[index])
                    index += 1
                }
                // An unterminated fence happens constantly mid-stream. Render
                // what has arrived so far as code rather than dropping it.
                if closed || !code.isEmpty {
                    blocks.append(.code(language: language, code: code.joined(separator: "\n")))
                }
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                flushQuote()
                // A blank line between items doesn't end a list.
                if !(items.isEmpty || nextIsListItem(lines, after: index)) { flushList() }
                index += 1
                continue
            }

            if let heading = heading(trimmed) {
                flushAll()
                blocks.append(heading)
                index += 1
                continue
            }

            if isRule(trimmed) {
                flushAll()
                blocks.append(.rule)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                flushList()
                var body = trimmed.dropFirst()
                if body.hasPrefix(" ") { body = body.dropFirst() }
                quote.append(String(body))
                index += 1
                continue
            }
            flushQuote()

            if index + 1 < lines.count, trimmed.contains("|"), isTableSeparator(lines[index + 1]) {
                flushAll()
                let header = cells(of: trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let rowLine = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !rowLine.isEmpty, rowLine.contains("|") else { break }
                    var row = cells(of: rowLine)
                    if row.count < header.count {
                        row += Array(repeating: "", count: header.count - row.count)
                    }
                    rows.append(Array(row.prefix(header.count)))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            if let (indent, marker, text) = listMarker(line) {
                flushParagraph()
                while let last = listIndents.last, indent < last { listIndents.removeLast() }
                if listIndents.last.map({ indent > $0 }) ?? true { listIndents.append(indent) }
                items.append(ListItem(marker: marker, depth: max(0, listIndents.count - 1), text: text))
                index += 1
                continue
            }

            // A plain line right after an item continues it.
            if !items.isEmpty && paragraph.isEmpty {
                items[items.count - 1].text += "\n" + trimmed
                index += 1
                continue
            }

            paragraph.append(line)
            index += 1
        }

        flushAll()
        return blocks
    }

    nonisolated private static func heading(_ line: String) -> Block? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }   // "#hashtag" is prose
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Optional closing hashes: "## Title ##".
        while text.hasSuffix("#") { text.removeLast() }
        return .heading(level: hashes, text: text.trimmingCharacters(in: .whitespaces))
    }

    nonisolated private static func isRule(_ line: String) -> Bool {
        let compact = line.filter { $0 != " " }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    nonisolated private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-") else { return false }
        let parts = cells(of: trimmed)
        return !parts.isEmpty && parts.allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { "-:".contains($0) } && cell.contains("-")
        }
    }

    nonisolated private static func cells(of line: String) -> [String] {
        var body = Substring(line)
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|") { body = body.dropLast() }
        return body.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// `- item`, `* item`, `+ item`, `1. item`, `1) item`, `- [x] item`.
    /// Returns the indent width (tabs count as four), the marker, and the text.
    nonisolated private static func listMarker(_ line: String) -> (Int, ListItem.Marker, String)? {
        var indent = 0
        for character in line {
            if character == " " { indent += 1 } else if character == "\t" { indent += 4 } else { break }
        }
        let body = line.drop { $0 == " " || $0 == "\t" }

        if let first = body.first, "-*+".contains(first), body.dropFirst().first == " " {
            let text = body.dropFirst(2).trimmingCharacters(in: .whitespaces)
            for (prefix, checked) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where text.hasPrefix(prefix) {
                return (indent, .task(checked: checked), String(text.dropFirst(prefix.count)))
            }
            return (indent, .bullet, text)
        }

        let digits = body.prefix { $0.isASCII && $0.isNumber }
        guard (1...9).contains(digits.count) else { return nil }
        let after = body.dropFirst(digits.count)
        guard let delimiter = after.first, delimiter == "." || delimiter == ")",
              after.dropFirst().first == " " else { return nil }
        let text = after.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return (indent, .ordered(String(digits) + String(delimiter)), text)
    }

    nonisolated private static func nextIsListItem(_ lines: [String], after index: Int) -> Bool {
        var next = index + 1
        while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).isEmpty { next += 1 }
        return next < lines.count && listMarker(lines[next]) != nil
    }
}

/// A fenced code block with its language and a copy button.
private struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    Clipboard.copy(code)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .touchTarget()
                .accessibilityLabel(copied ? "Copied" : "Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Styled text for prose blocks already built. A streaming reply is
/// re-rendered about 30 times a second, and every block but the last is
/// unchanged between frames, so only that one is rebuilt. Keyed by the body
/// font size too, since fonts follow Dynamic Type.
nonisolated enum ProseBlockCache {
    private struct Key: Hashable {
        let block: MarkdownText.Block
        let bodySize: CGFloat
    }

    /// Cleared, rather than evicted one by one, once it holds this many.
    static let limit = 512

    // Unchecked: NSAttributedString values are immutable once stored, and
    // every access goes through the lock.
    private static let storage = OSAllocatedUnfairLock(uncheckedState: [Key: NSAttributedString]())

    static func text(for block: MarkdownText.Block, make: () -> NSAttributedString) -> NSAttributedString {
        let key = Key(block: block, bodySize: SelectableStyle.bodyFont.pointSize)
        if let cached = storage.withLockUnchecked({ $0[key] }) { return cached }
        let text = make().copy() as! NSAttributedString
        storage.withLockUnchecked { cache in
            if cache.count >= limit { cache.removeAll(keepingCapacity: true) }
            cache[key] = text
        }
        return text
    }

    static var count: Int { storage.withLockUnchecked { $0.count } }
}

/// Fonts and colours for `MarkdownText.attributedProse`, matching the
/// SwiftUI styles the transcript uses.
nonisolated enum SelectableStyle {
    #if canImport(UIKit)
    typealias PlatformFont = UIFont
    typealias PlatformColor = UIColor
    static var labelColor: PlatformColor { .label }
    static var secondaryColor: PlatformColor { .secondaryLabel }
    #else
    typealias PlatformFont = NSFont
    typealias PlatformColor = NSColor
    static var labelColor: PlatformColor { .labelColor }
    static var secondaryColor: PlatformColor { .secondaryLabelColor }
    #endif

    static var bodyFont: PlatformFont { .preferredFont(forTextStyle: .body) }

    /// Space between blocks, as the stacked SwiftUI views had.
    static let blockSpacing: CGFloat = 12
    static let quoteIndent: CGFloat = 14

    static var codeFont: PlatformFont {
        .monospacedSystemFont(ofSize: PlatformFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
    }

    static var base: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: labelColor]
    }

    static func headingFont(_ level: Int) -> PlatformFont {
        let style: PlatformFont.TextStyle
        switch level {
        case 1: style = .title2
        case 2: style = .title3
        case 3: style = .headline
        default: style = .subheadline
        }
        return PlatformFont.preferredFont(forTextStyle: style).withTraits(bold: true)
    }
}

nonisolated extension SelectableStyle.PlatformFont {
    func withTraits(bold: Bool = false, italic: Bool = false) -> SelectableStyle.PlatformFont {
        #if canImport(UIKit)
        var traits = fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
        #else
        var traits = fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        return NSFont(descriptor: fontDescriptor.withSymbolicTraits(traits), size: 0) ?? self
        #endif
    }
}
