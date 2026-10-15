import Foundation

/// Режим сборки конспекта (SPEC, раздел 4, пункт 4).
enum AssemblyMode: String, Codable, Sendable {
    case notesOnly
    case notesWithSlides
    case slidesOnly

    var title: String {
        switch self {
        case .notesOnly: "по рукописи"
        case .notesWithSlides: "по рукописи со сверкой по слайдам"
        case .slidesOnly: "по слайдам"
        }
    }
}

/// Страница, попавшая в сборку: номер — позиция в своём разделе лекции.
struct AssemblyPage: Equatable, Sendable {
    var id: String
    var number: Int
    var text: String
}

/// Тексты, из которых собирается конспект.
struct AssemblyInput: Equatable, Sendable {
    var notes: [AssemblyPage] = []
    var slides: [AssemblyPage] = []
    /// Страницы рукописи без текста (не распознаны) — в сборку не попадают.
    var unrecognizedNotes = 0
    /// Слайды без текста (картинки, которые не распознаны).
    var unrecognizedSlides = 0

    var mode: AssemblyMode? {
        switch (notes.isEmpty, slides.isEmpty) {
        case (false, true): .notesOnly
        case (false, false): .notesWithSlides
        case (true, false): .slidesOnly
        case (true, true): nil
        }
    }

    var totalChars: Int { (notes + slides).reduce(0) { $0 + $1.text.count } }

    /// Хеш входных данных конспекта: тексты страниц и их порядок (SPEC, раздел 4.1).
    var hash: String {
        let parts = ["notes"] + notes.map { "\($0.id):\(FileHash.sha256($0.text))" }
            + ["slides"] + slides.map { "\($0.id):\(FileHash.sha256($0.text))" }
        return FileHash.sha256(parts.joined(separator: "\n"))
    }

    /// Собирает входные данные из `meta.json` и текстов страниц. Слайды «не включать в конспект» пропускаются.
    static func collect(meta: LectureMeta, texts: PageTextStore) -> AssemblyInput {
        var input = AssemblyInput()
        for (index, page) in meta.notes.enumerated() {
            let text = (texts.read(page.id, in: .notes) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { input.unrecognizedNotes += 1 } else {
                input.notes.append(AssemblyPage(id: page.id, number: index + 1, text: text))
            }
        }
        for (index, page) in meta.slides.enumerated() where !page.excluded {
            let text = (texts.read(page.id, in: .slides) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if page.needsRecognition { input.unrecognizedSlides += 1 }
            if !text.isEmpty, !page.needsRecognition {
                input.slides.append(AssemblyPage(id: page.id, number: index + 1, text: text))
            }
        }
        return input
    }
}

/// Одна часть сборки.
struct AssemblyPart: Equatable, Sendable {
    var notes: [AssemblyPage]
    var slides: [AssemblyPage]
}

struct AssemblyPlan: Equatable, Sendable {
    var mode: AssemblyMode
    var parts: [AssemblyPart]

    /// Части нужно склеить финальным проходом.
    var needsMerge: Bool { parts.count > 1 }
    /// Всего вызовов модели.
    var calls: Int { parts.count + (needsMerge ? 1 : 0) }
}

/// Разбиение длинной лекции на части (SPEC, разделы 4 и 13).
enum AssemblyPlanner {
    /// Сколько соседних слайдов добавлять к пропорциональному срезу с каждой стороны.
    static let slideOverlap = 2

    static func plan(_ input: AssemblyInput, threshold: Int) -> AssemblyPlan? {
        guard let mode = input.mode else { return nil }
        let threshold = max(threshold, 1000)
        if input.totalChars <= threshold {
            return AssemblyPlan(mode: mode, parts: [AssemblyPart(notes: input.notes, slides: input.slides)])
        }
        switch mode {
        case .notesOnly:
            return AssemblyPlan(mode: mode, parts: chunk(input.notes, limit: threshold).map { AssemblyPart(notes: $0, slides: []) })
        case .slidesOnly:
            return AssemblyPlan(mode: mode, parts: chunk(input.slides, limit: threshold).map { AssemblyPart(notes: [], slides: $0) })
        case .notesWithSlides:
            // Рукопись режется так, чтобы вместе со своей долей слайдов часть укладывалась в порог.
            let notesChars = input.notes.reduce(0) { $0 + $1.text.count }
            let share = Double(notesChars) / Double(max(input.totalChars, 1))
            let chunks = chunk(input.notes, limit: max(Int(Double(threshold) * share), 1))
            let parts = chunks.enumerated().map { k, notes in
                AssemblyPart(notes: notes, slides: slice(input.slides, part: k, of: chunks.count))
            }
            return AssemblyPlan(mode: mode, parts: parts)
        }
    }

    /// Жадное разбиение по страницам с перекрытием в одну страницу: каждая следующая часть
    /// начинается с последней страницы предыдущей. Страница больше лимита идёт отдельной частью.
    static func chunk(_ pages: [AssemblyPage], limit: Int) -> [[AssemblyPage]] {
        guard !pages.isEmpty else { return [] }
        var chunks: [[AssemblyPage]] = []
        var start = 0
        while start < pages.count {
            var end = start
            var size = pages[start].text.count
            while end + 1 < pages.count, size + pages[end + 1].text.count <= limit {
                end += 1
                size += pages[end].text.count
            }
            chunks.append(Array(pages[start...end]))
            if end == pages.count - 1 { break }
            // Перекрытие: следующая часть начинается с последней страницы, если это даёт продвижение вперёд.
            start = end > start ? end : end + 1
        }
        return chunks
    }

    /// Часть k из n получает примерно k-ю n-ю долю слайдов по порядку плюс по `slideOverlap` соседних.
    static func slice(_ slides: [AssemblyPage], part k: Int, of n: Int) -> [AssemblyPage] {
        guard !slides.isEmpty, n > 0 else { return [] }
        let count = slides.count
        let lower = max(0, Int((Double(k) * Double(count) / Double(n)).rounded(.down)) - slideOverlap)
        let upper = min(count, Int((Double(k + 1) * Double(count) / Double(n)).rounded(.up)) + slideOverlap)
        return lower < upper ? Array(slides[lower..<upper]) : []
    }

    /// Таймаут сборки растёт с объёмом (SPEC, раздел 2.5): от 3 минут, около 1 с на 100 символов, не больше 30 минут.
    static func timeout(chars: Int) -> TimeInterval {
        min(1800, max(180, 120 + Double(chars) / 100))
    }
}

extension PromptLibrary {
    static let assemblySystemPrompt = """
    Ты собираешь конспект лекции из уже распознанных страниц. Изображений нет, инструменты не нужны. \
    В ответе выведи только Markdown конспекта, без вступлений и пояснений.
    """

    static func pagesBlock(_ pages: [AssemblyPage], label: String) -> String {
        pages.map { "--- \(label) \($0.number) ---\n\($0.text)" }.joined(separator: "\n\n")
    }

    /// Промпт сборки одной части. Для длинной лекции добавляется пояснение, какая это часть.
    func assemblyPrompt(mode: AssemblyMode, part: AssemblyPart, index: Int, of count: Int,
                        subject: String, topic: String) throws -> String {
        let name = switch mode {
        case .notesOnly: "assemble.md"
        case .notesWithSlides: "assemble-with-slides.md"
        case .slidesOnly: "assemble-slides-only.md"
        }
        let pages = mode == .slidesOnly ? Self.pagesBlock(part.slides, label: "Слайд") : Self.pagesBlock(part.notes, label: "Страница")
        var prompt = Self.render(try template(name), values: [
            "предмет": subject,
            "тема": topic,
            "вставка_предмета": subjectInsert(subject),
            "страницы": pages,
            "слайды": Self.pagesBlock(part.slides, label: "Слайд"),
        ])
        if count > 1 {
            let span = mode == .slidesOnly ? part.slides : part.notes
            let range = span.first.map { first in
                "\(mode == .slidesOnly ? "слайды" : "страницы") \(first.number)–\(span.last?.number ?? first.number)"
            } ?? ""
            prompt += "\n\nЭто часть \(index + 1) из \(count) длинной лекции (\(range)). Собери конспект только этой части. "
                + "Соседние части перекрываются на одну страницу; потом их склеят, поэтому ничего не обрывай и не подводи итогов."
        }
        return prompt
    }

    func mergePrompt(parts: [String], subject: String, topic: String) throws -> String {
        let joined = parts.enumerated().map { "=== Часть \($0.offset + 1) ===\n\($0.element)" }.joined(separator: "\n\n")
        return Self.render(try template("assemble-merge-chunks.md"), values: [
            "предмет": subject, "тема": topic, "конспект": joined,
        ])
    }
}

enum MarkdownCleanup {
    /// Снимает обёртку ```markdown … ```, если модель завернула в неё весь ответ.
    static func unwrap(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```") else { return trimmed }
        let lines = trimmed.components(separatedBy: "\n")
        guard lines.count >= 2, lines[0].trimmingCharacters(in: .whitespaces).range(of: #"^```(markdown|md)?$"#,
                                                                                         options: .regularExpression) != nil
        else { return trimmed }
        return lines.dropFirst().dropLast().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
