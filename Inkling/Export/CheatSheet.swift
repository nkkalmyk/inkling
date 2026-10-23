import Foundation

/// Шпаргалка по конспекту: определения, законы, теоремы и вынесенные формулы подряд, по разделам. Собирается из готового
/// текста без вызовов модели: берётся только то, что уже есть в конспекте.
enum CheatSheet {
    /// Названия определений и законов в начале абзаца (как `p.definition` в рендере).
    private static let definitionStart = try! NSRegularExpression(
        pattern: #"^\**\s*(?:Закон|Теорема|Определение|Правило|Принцип|Следствие|Лемма|Аксиома|Постулат|Уравнение|Формула|Свойство)"#,
        options: [.caseInsensitive])
    private static let subsectionMarker = "\u{1}"
    /// Вынесенная формула считается ключевой, если она короткая, не продолжает выкладку (`= …`) и не заканчивается знаком `=`.
    private static let maxFormulaLength = 220

    /// Разделы, которые в шпаргалку не идут.
    private static let skippedSections = ["оглавление", "источники", "пример", "типовые вопросы", "частые ошибки"]

    /// `nil`, если в конспекте нечего собирать.
    static func build(from markdown: String, subject: String, topic: String) -> String? {
        struct Section { var title: String; var items: [String] = [] }
        var sections: [Section] = []
        var skipping = false
        var inFence = false
        var block: [String] = []

        func flush() {
            defer { block = [] }
            guard !skipping, let item = pick(block), !sections.isEmpty else { return }
            sections[sections.count - 1].items.append(item)
        }

        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle(); block = []; continue }
            if inFence { continue }
            if trimmed.hasPrefix("#") {
                flush()
                let level = trimmed.prefix { $0 == "#" }.count
                let title = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if level == 1 { skipping = true; continue }
                if level == 2 {
                    skipping = skippedSections.contains { title.lowercased().contains($0) }
                    sections.append(Section(title: title))
                } else if !skipping, !sections.isEmpty {
                    // Подраздел: название жирной строкой, чтобы шпаргалка сохраняла порядок темы.
                    sections[sections.count - 1].items.append(subsectionMarker + "**\(title)**")
                }
                continue
            }
            if trimmed.isEmpty { flush() } else { block.append(trimmed) }
        }
        flush()

        // Название подраздела без содержимого под ним не нужно; пустые разделы тоже.
        let body = sections.compactMap { section -> String? in
            var items: [String] = []
            for (index, item) in section.items.enumerated() {
                if item.hasPrefix(subsectionMarker) {
                    let next = section.items.dropFirst(index + 1).first
                    if let next, !next.hasPrefix(subsectionMarker) { items.append(String(item.dropFirst(subsectionMarker.count))) }
                } else {
                    items.append(item)
                }
            }
            return items.isEmpty ? nil : "## \(section.title)\n\n" + items.joined(separator: "\n\n")
        }
        guard !body.isEmpty else { return nil }
        return "# Шпаргалка\n\n\(subject) — \(topic)\n\n*Определения, законы и формулы конспекта подряд.*\n\n" + body.joined(separator: "\n\n") + "\n"
    }

    /// Абзац определения (с названием жирным в начале), цитата-определение или вынесенная формула `$$…$$`.
    private static func pick(_ block: [String]) -> String? {
        guard let first = block.first else { return nil }
        let text = block.joined(separator: "\n")
        if first.hasPrefix("$$"), text.hasSuffix("$$") {
            let inner = text.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespacesAndNewlines)
            let continuesDerivation = inner.hasPrefix("=") || inner.hasSuffix("=") || inner.hasSuffix("\\")
            let isTable = inner.contains("\\begin{array}")
            return text.count <= maxFormulaLength && !continuesDerivation && !isTable ? text : nil
        }
        let plain = first.hasPrefix(">") ? first.drop { $0 == ">" || $0 == " " } : Substring(first)
        let range = NSRange(plain.startIndex..., in: plain)
        guard definitionStart.firstMatch(in: String(plain), range: range) != nil, plain.contains("**") else { return nil }
        // Название должно быть выделено жирным: «**Закон Гесса:** …». Цитата остаётся цитатой.
        return text
    }
}
