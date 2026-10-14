import Foundation

/// CSV для Anki (SPEC, раздел 8): карточки, по галочке ещё вопросы. Формат — текст с табуляцией и заголовками
/// Anki; поля в HTML; формулы в разделителях MathJax `\(…\)` и `\[…\]` (mhchem в Anki встроен, см. docs/cli-notes.md).
enum AnkiExporter {
    static func export(_ study: StudyMaterials, progress: StudyProgress, subject: String, topic: String,
                       includeQuestions: Bool) -> String {
        let tags = tag(subject: subject, topic: topic)
        var lines = ["#separator:tab", "#html:true", "#tags column:3"]
        for card in study.flashcards where !progress.flagged.contains(card.id) {
            lines.append(row(front: card.front, back: card.back, tags: tags))
        }
        if includeQuestions {
            for q in study.questions where !progress.flagged.contains(q.id) {
                var back = q.answer
                if let solution = q.solution, !solution.isEmpty { back += "\n\n**Решение.** " + solution }
                lines.append(row(front: q.question, back: back, tags: tags + " вопрос"))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Тег вида `предмет::тема`; пробелы в тегах Anki недопустимы.
    static func tag(subject: String, topic: String) -> String {
        func clean(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "::", with: ":")
                .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: "_")
        }
        return "\(clean(subject))::\(clean(topic))"
    }

    private static func row(front: String, back: String, tags: String) -> String {
        [field(front), field(back), tags].joined(separator: "\t")
    }

    /// Поле: формулы в синтаксисе MathJax, HTML экранирован (кроме формул), переносы строк — `<br>`, табуляции — пробелы.
    static func field(_ markdown: String) -> String {
        var out = ""
        for segment in segments(markdown) {
            switch segment {
            case .text(let text):
                out += inlineMarkdown(escapeHTML(text))
            case .math(let tex, let display):
                out += display ? "\\[\(escapeHTML(tex))\\]" : "\\(\(escapeHTML(tex))\\)"
            }
        }
        return out.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    enum Segment: Equatable {
        case text(String)
        case math(String, display: Bool)
    }

    /// Делит текст на обычные куски и формулы `$…$` / `$$…$$` по тем же правилам, что рендер конспекта.
    static func segments(_ text: String) -> [Segment] {
        var result: [Segment] = []
        var buffer = ""
        let chars = Array(text)
        var i = 0
        func flush() {
            if !buffer.isEmpty { result.append(.text(buffer)); buffer = "" }
        }
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, chars[i + 1] == "$" {
                buffer.append("$")
                i += 2
                continue
            }
            if c == "$", i + 1 < chars.count, chars[i + 1] == "$",
               let end = find("$$", in: chars, from: i + 2) {
                flush()
                result.append(.math(String(chars[(i + 2)..<end]), display: true))
                i = end + 2
                continue
            }
            if c == "$", let end = inlineEnd(chars, start: i) {
                flush()
                result.append(.math(String(chars[(i + 1)..<end]), display: false))
                i = end + 1
                continue
            }
            buffer.append(c)
            i += 1
        }
        flush()
        return result
    }

    private static func find(_ needle: String, in chars: [Character], from start: Int) -> Int? {
        let n = Array(needle)
        guard start <= chars.count - n.count else { return nil }
        for i in start...(chars.count - n.count) where Array(chars[i..<(i + n.count)]) == n { return i }
        return nil
    }

    private static func inlineEnd(_ chars: [Character], start: Int) -> Int? {
        guard start + 1 < chars.count, !chars[start + 1].isWhitespace else { return nil }
        var j = start + 1
        while j < chars.count {
            let c = chars[j]
            if c == "\n", j + 1 < chars.count, chars[j + 1] == "\n" { return nil }
            if c == "\\" { j += 2; continue }
            if c == "$" {
                let nextIsDigit = j + 1 < chars.count && chars[j + 1].isNumber
                if !chars[j - 1].isWhitespace && !nextIsDigit { return j }
            }
            j += 1
        }
        return nil
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Минимум Markdown внутри строки: **жирный** и *курсив*.
    private static func inlineMarkdown(_ s: String) -> String {
        s.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "<b>$1</b>", options: .regularExpression)
            .replacingOccurrences(of: #"(?<![\*\w])\*(?!\s)(.+?)(?<!\s)\*(?![\*\w])"#, with: "<i>$1</i>", options: .regularExpression)
    }
}
