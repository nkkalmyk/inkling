import Foundation

/// Дополнение конспекта («Дополнить»): помеченные блоки поверх авторского текста.
/// Всё, что добавила модель, распознаётся по разметке, поэтому добавления можно найти, проверить, убрать
/// и убедиться, что авторский текст остался прежним.
///
/// Разметка в `konspekt.md`:
/// - `## 🧭 Главное` и список под ним — краткое резюме в начале;
/// - цитаты, начинающиеся с `> 💡`, `> 📝` или `> 🔗` — пояснение, пример, связи;
/// - блоки кода с языком `plot` (график по формулам) и `svg` (схема);
/// - термины в тексте выделяются `**жирным**` (текст при этом не меняется).
enum Enrichment {
    enum Kind: String, Equatable, Sendable {
        case summary, explanation, example, link, plot, svg

        var title: String {
            switch self {
            case .summary: "Главное"
            case .explanation: "Пояснение"
            case .example: "Пример"
            case .link: "Связи"
            case .plot: "График"
            case .svg: "Схема"
            }
        }
    }

    struct Addition: Equatable, Sendable {
        var kind: Kind
        /// Диапазон строк (включительно слева, исключительно справа) в исходном тексте.
        var lines: Range<Int>
        var text: String
    }

    // MARK: Поиск добавлений

    static let summaryHeading = "## 🧭 Главное"

    static func additions(in markdown: String) -> [Addition] {
        let lines = markdown.components(separatedBy: "\n")
        var result: [Addition] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if let fence = fenceMarker(line) {
                let language = line.trimmingCharacters(in: .whitespaces).dropFirst(fence.count)
                    .trimmingCharacters(in: .whitespaces).lowercased()
                var end = i + 1
                while end < lines.count, !isFenceClose(lines[end], marker: fence) { end += 1 }
                end = min(end + 1, lines.count)
                if language == "plot" || language == "svg" {
                    result.append(Addition(kind: language == "plot" ? .plot : .svg, lines: i..<end,
                                           text: lines[i..<end].joined(separator: "\n")))
                }
                i = end
                continue
            }
            if isSummaryHeading(line) {
                var end = i + 1
                while end < lines.count, !lines[end].hasPrefix("#"), fenceMarker(lines[end]) == nil { end += 1 }
                result.append(Addition(kind: .summary, lines: i..<end, text: lines[i..<end].joined(separator: "\n")))
                i = end
                continue
            }
            if let kind = calloutKind(line) {
                var end = i + 1
                while end < lines.count, lines[end].hasPrefix(">"), calloutKind(lines[end]) == nil,
                      !isAuthorCallout(lines[end]) { end += 1 }
                result.append(Addition(kind: kind, lines: i..<end, text: lines[i..<end].joined(separator: "\n")))
                i = end
                continue
            }
            i += 1
        }
        return result
    }

    private static func fenceMarker(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) {
            return String(trimmed.prefix { $0 == marker.first })
        }
        return nil
    }

    private static func isFenceClose(_ line: String, marker: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix(marker) && trimmed.allSatisfy { $0 == marker.first }
    }

    private static func isSummaryHeading(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return false }
        return trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).hasPrefix("🧭")
    }

    private static func calloutKind(_ line: String) -> Kind? {
        guard line.hasPrefix(">") else { return nil }
        let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("💡") { return .explanation }
        if body.hasPrefix("📝") { return .example }
        if body.hasPrefix("🔗") { return .link }
        return nil
    }

    /// Блоки `⚠️` и `📎` принадлежат сборке и не считаются добавлениями.
    private static func isAuthorCallout(_ line: String) -> Bool {
        let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
        // «⚠️» — символ с вариационным селектором: для String это другой графем, поэтому сравниваем скаляры.
        return body.unicodeScalars.first == "\u{26A0}" || body.hasPrefix("📎")
    }

    // MARK: Удаление и проверка

    /// Авторский текст конспекта: блоки вырезаются только у конспекта, дополненного кнопкой «Дополнить». В учебной сборке
    /// блоки `💡 📝 🔗`, `plot` и `svg` пишет сама сборка, это часть конспекта, и вырезать их нельзя.
    static func baseText(_ markdown: String, info: ArtifactInfo?) -> String {
        info?.enrichment == nil ? markdown : removing(from: markdown)
    }

    /// Текст без указанных добавлений (по номерам в `additions(in:)`); `nil` — без всех.
    static func removing(_ indices: Set<Int>? = nil, from markdown: String) -> String {
        let found = additions(in: markdown)
        var drop = Set<Int>()
        for (index, addition) in found.enumerated() where indices?.contains(index) ?? true {
            drop.formUnion(addition.lines)
        }
        guard !drop.isEmpty else { return markdown }
        var kept: [String] = []
        for (index, line) in markdown.components(separatedBy: "\n").enumerated() where !drop.contains(index) {
            // Пустые строки, оставшиеся от вырезанного блока, не копятся.
            if line.trimmingCharacters(in: .whitespaces).isEmpty, kept.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                continue
            }
            kept.append(line)
        }
        var text = kept.joined(separator: "\n")
        while text.hasPrefix("\n") { text.removeFirst() }
        return text
    }

    /// Авторский текст для сравнения: без добавлений, без `**` и с одинаковыми пробелами.
    static func comparableText(_ markdown: String) -> String {
        removing(from: markdown)
            .replacingOccurrences(of: "**", with: "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Модель могла «заодно поправить» слова автора: тогда результат отвергается.
    static func preservesAuthorText(original: String, enriched: String) -> Bool {
        comparableText(original) == comparableText(enriched)
    }

    // MARK: Проверка добавлений моделью

    /// Нумерованный список добавлений для проверяющего прохода.
    static func numberedList(_ additions: [Addition]) -> String {
        additions.enumerated().map { index, addition in
            "[\(index + 1)] (\(addition.kind.title))\n\(addition.text)"
        }.joined(separator: "\n\n")
    }

    static let verificationSchema = """
    {"type":"object","additionalProperties":false,"required":["problems"],"properties":{"problems":{"type":"array","items":\
    {"type":"object","additionalProperties":false,"required":["id","issue"],"properties":\
    {"id":{"type":"integer","minimum":1},"issue":{"type":"string","minLength":1}}}}}}
    """

    struct Problem: Equatable, Sendable {
        var id: Int
        var issue: String
    }

    /// Номера (с единицы) и причины из ответа проверяющего прохода; мусор отбрасывается.
    static func parseProblems(_ json: Data?, count: Int) -> [Problem]? {
        guard let json, let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let items = object["problems"] as? [[String: Any]] else { return nil }
        return items.compactMap { item in
            guard let id = item["id"] as? Int, (1...max(count, 1)).contains(id), count > 0 else { return nil }
            return Problem(id: id, issue: (item["issue"] as? String) ?? "")
        }
    }
}
