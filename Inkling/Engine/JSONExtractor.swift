import Foundation

/// Достаёт JSON-объект из ответа модели, даже если он обёрнут в текст или в блок ```json (SPEC, раздел 5).
enum JSONExtractor {
    static func object(in text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isObject(trimmed) { return Data(trimmed.utf8) }

        // Блоки кода ```json … ``` или ``` … ```.
        if let regex = try? NSRegularExpression(pattern: #"```(?:json|JSON)?\s*\n?([\s\S]*?)```"#) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text) {
                    let block = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
                    if isObject(block) { return Data(block.utf8) }
                }
            }
        }

        // Первый сбалансированный объект {…}, который парсится.
        var start = text.firstIndex(of: "{")
        while let open = start {
            if let close = matchingBrace(in: text, from: open) {
                let candidate = String(text[open...close])
                if isObject(candidate) { return Data(candidate.utf8) }
            }
            start = text[text.index(after: open)...].firstIndex(of: "{")
        }
        return nil
    }

    private static func isObject(_ text: String) -> Bool {
        guard text.hasPrefix("{") else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) is [String: Any]
    }

    /// Индекс закрывающей скобки с учётом строк и экранирования.
    private static func matchingBrace(in text: String, from open: String.Index) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var i = open
        while i < text.endIndex {
            let c = text[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 { return i }
            }
            i = text.index(after: i)
        }
        return nil
    }
}
