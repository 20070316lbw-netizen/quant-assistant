import SwiftUI

/// Agent 回复的 Markdown 渲染。
///
/// SwiftUI 的 `Text(AttributedString(markdown:))` 只认行内语法（粗体、斜体、行内代码、
/// 链接），标题、列表、表格、代码块会原样露出 `#`、`|---|` 这些符号——DeepSeek 很爱
/// 输出这些。这里自己做一层很小的"块级"解析：把文本切成标题/段落/列表项/表格/代码块/
/// 引用/分隔线，每块里的文字再交给系统的行内 Markdown 解析。不引第三方依赖；
/// 流式输出时每来一个 chunk 整段重解析一次，回复一般几 KB，开销可以忽略。
/// 没闭合的代码块（流式输出到一半）按"代码块一直到结尾"处理，不会闪成普通段落。
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case listItem(indent: Int, marker: String, text: String)
    case code(language: String?, code: String)
    case quote(String)
    case table(header: [String], alignments: [TableAlignment], rows: [[String]])
    case rule

    enum TableAlignment: Equatable { case leading, center, trailing }
}

enum MarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var i = 0

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph.removeAll()
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 代码块
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                i += 1 // 跳过闭合的 ```（没有闭合时越界，循环自然结束）
                blocks.append(.code(language: language.isEmpty ? nil : language, code: code.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // 表格：当前行有 |，下一行是 |---|:--:| 这种分隔行
            if trimmed.contains("|"), i + 1 < lines.count, let alignments = separatorAlignments(lines[i + 1]) {
                let header = cells(trimmed)
                if !header.isEmpty {
                    flushParagraph()
                    var rows: [[String]] = []
                    i += 2
                    while i < lines.count {
                        let rowLine = lines[i].trimmingCharacters(in: .whitespaces)
                        guard rowLine.contains("|"), !rowLine.isEmpty else { break }
                        rows.append(cells(rowLine))
                        i += 1
                    }
                    let width = max(header.count, alignments.count, rows.map(\.count).max() ?? 0)
                    blocks.append(.table(
                        header: pad(header, to: width),
                        alignments: pad(alignments, to: width, with: .leading),
                        rows: rows.map { pad($0, to: width) }))
                    continue
                }
            }

            // 标题
            if let heading = headingMatch(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                i += 1
                continue
            }

            // 分隔线
            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                i += 1
                continue
            }

            // 引用（连续的 > 行合并成一块）
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while i < lines.count {
                    let q = lines[i].trimmingCharacters(in: .whitespaces)
                    guard q.hasPrefix(">") else { break }
                    quoted.append(String(q.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }

            // 列表项
            if let item = listItemMatch(line) {
                flushParagraph()
                var text = item.text
                i += 1
                // 紧跟着的、缩进过的非列表行算这一项的续行
                while i < lines.count {
                    let next = lines[i]
                    let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                    guard !nextTrimmed.isEmpty, next.hasPrefix("  "), listItemMatch(next) == nil else { break }
                    text += "\n" + nextTrimmed
                    i += 1
                }
                blocks.append(.listItem(indent: item.indent, marker: item.marker, text: text))
                continue
            }

            paragraph.append(trimmed)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    // MARK: - 行级匹配

    static func headingMatch(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() } // "## 标题 ##"
        return (hashes.count, text.trimmingCharacters(in: .whitespaces))
    }

    static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    static func listItemMatch(_ line: String) -> (indent: Int, marker: String, text: String)? {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let indentWidth = leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let body = line.dropFirst(leading.count)
        if let first = body.first, "-*+".contains(first), body.dropFirst().first == " " {
            return (indentWidth / 2, "•", String(body.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        }
        let digits = body.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let afterDigits = body.dropFirst(digits.count)
            if let punct = afterDigits.first, punct == "." || punct == ")", afterDigits.dropFirst().first == " " {
                return (indentWidth / 2, "\(digits).", String(afterDigits.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    /// `|---|:--:|--:|` 这种表格分隔行 -> 每列对齐方式；不是分隔行返回 nil。
    static func separatorAlignments(_ line: String) -> [MarkdownBlock.TableAlignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // 必须带 |，否则 "---" 这种分隔线/setext 标题会被误认成表格分隔行。
        guard trimmed.contains("-"), trimmed.contains("|") else { return nil }
        let parts = cells(trimmed)
        guard !parts.isEmpty else { return nil }
        var result: [MarkdownBlock.TableAlignment] = []
        for part in parts {
            let p = part.replacingOccurrences(of: " ", with: "")
            let core = p.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !core.isEmpty, core.allSatisfy({ $0 == "-" }) else { return nil }
            switch (p.hasPrefix(":"), p.hasSuffix(":")) {
            case (true, true): result.append(.center)
            case (false, true): result.append(.trailing)
            default: result.append(.leading)
            }
        }
        return result
    }

    /// "| a | b |" -> ["a", "b"]；首尾的 | 可有可无，`\|` 当普通字符。
    static func cells(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") && !s.hasSuffix("\\|") { s.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for ch in s {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "|" { cells.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
            current.append(ch)
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func pad<T>(_ array: [T], to width: Int, with filler: T) -> [T] {
        array.count >= width ? Array(array.prefix(width)) : array + Array(repeating: filler, count: width - array.count)
    }

    private static func pad(_ array: [String], to width: Int) -> [String] {
        pad(array, to: width, with: "")
    }
}

// MARK: - 渲染

struct MarkdownView: View {
    let blocks: [MarkdownBlock]

    init(_ source: String) {
        blocks = MarkdownParser.parse(source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 4 : 2)
        case .paragraph(let text):
            inline(text)
        case .listItem(let indent, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: marker == "•" ? 10 : 18, alignment: .trailing)
                inline(text)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .code(let language, let code):
            VStack(alignment: .leading, spacing: 4) {
                if let language {
                    Text(language).font(.caption2).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code).font(.system(.callout, design: .monospaced))
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 3)
                inline(text).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .table(let header, let alignments, let rows):
            table(header: header, alignments: alignments, rows: rows)
        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    private func table(header: [String], alignments: [MarkdownBlock.TableAlignment], rows: [[String]]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            GridRow {
                ForEach(header.indices, id: \.self) { col in
                    inline(header[col])
                        .fontWeight(.semibold)
                        .gridColumnAlignment(horizontal(alignments[col]))
                }
            }
            Divider()
            ForEach(rows.indices, id: \.self) { r in
                GridRow {
                    ForEach(rows[r].indices, id: \.self) { col in
                        inline(rows[r][col]).monospacedDigit()
                    }
                }
            }
        }
        .padding(8)
        .background(Color.black.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func horizontal(_ alignment: MarkdownBlock.TableAlignment) -> HorizontalAlignment {
        switch alignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.bold()
        case 2: return .title3.bold()
        case 3: return .headline
        default: return .subheadline.bold()
        }
    }

    /// 行内 Markdown（**粗体**、*斜体*、`代码`、[链接](url)），保留换行。
    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return Text(attributed)
        }
        return Text(text)
    }
}
