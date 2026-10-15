import Foundation

/// Конспект в `.md` для заметочных программ (Obsidian и т. п., SPEC, раздел 8): YAML-шапка с метаданными,
/// заголовок лекции, без лишних пустых строк. Текст конспекта не переписывается.
enum MarkdownExporter {
    static func document(konspekt: String, subject: String, topic: String, date: CalendarDate) -> String {
        var body = normalized(konspekt)
        if !body.hasPrefix("# ") {
            body = "# \(topic)\n\n" + body
        }
        let header = [
            "---",
            "title: \(yaml(topic))",
            "subject: \(yaml(subject))",
            "date: \(date)",
            "source: Inkling",
            "---",
        ].joined(separator: "\n")
        return header + "\n\n" + body + "\n"
    }

    /// Без серий пустых строк; текст начинается с первой непустой строки. Пробелы в конце непустых строк
    /// сохраняются (два пробела в Markdown — перенос строки), блоки кода ```…``` не трогаются.
    static func normalized(_ text: String) -> String {
        var lines: [Substring] = []
        var blank = 0
        var inFence = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let isFence = line.trimmingPrefix(while: \.isWhitespace).hasPrefix("```")
            if inFence || isFence {
                if isFence { inFence.toggle() }
                blank = 0
                lines.append(line)
                continue
            }
            let isBlank = line.allSatisfy { $0 == " " || $0 == "\t" }
            let trimmed = isBlank ? "" : line
            if isBlank {
                blank += 1
                if blank > 1 || lines.isEmpty { continue }
            } else {
                blank = 0
            }
            lines.append(trimmed)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// Строка YAML в двойных кавычках.
    private static func yaml(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
