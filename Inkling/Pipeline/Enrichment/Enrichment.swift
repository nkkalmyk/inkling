import Foundation

/// Блоки, которые добавляла функция «Дополнить» (0.3–0.5, убрана): они остаются в старых конспектах.
/// Распознаются по разметке, чтобы учебные материалы и признак «Устарело» считались по авторскому тексту,
/// а рендер показывал их как вставки.
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
}
