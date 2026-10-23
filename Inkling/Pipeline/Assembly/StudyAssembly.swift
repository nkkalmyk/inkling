import Foundation

/// Стиль сборки конспекта. «Учебный» работает как чат с Claude: модель видит фотографии страниц целиком и свободно
/// перестраивает материал. «Точный» — прежняя сборка по распознанному тексту без права менять слова автора.
enum AssemblyStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case study
    case faithful

    var id: String { rawValue }

    var title: String {
        switch self {
        case .study: "Учебный конспект"
        case .faithful: "Точная сборка по тексту"
        }
    }

    var hint: String {
        switch self {
        case .study: "Модель смотрит на фото страниц и сама строит конспект: структура, пояснения, таблицы. Расходует больше лимита."
        case .faithful: "Только очистка распознанного текста: слова автора не меняются. Нужна, если важна дословность."
        }
    }
}

/// Страница тетради для учебной сборки: фото и черновая расшифровка (если страница уже распознана).
struct StudyPage: Equatable, Sendable {
    var id: String
    var number: Int
    var image: URL
    var draft: String
}

struct StudyPart: Equatable, Sendable {
    var notes: [StudyPage]
    var slides: [AssemblyPage]
}

struct StudyPlan: Equatable, Sendable {
    var parts: [StudyPart]

    var needsMerge: Bool { parts.count > 1 }
    var calls: Int { parts.count + (needsMerge ? 1 : 0) }
    var imageCount: Int { parts.reduce(0) { $0 + $1.notes.count } }
}

enum StudyAssemblyPlanner {
    /// Сколько фотографий уходит в один вызов: больше — модель хуже держит детали и чаще упирается в таймаут.
    /// Типовая лекция (3–8 страниц) собирается одним вызовом: законченный конспект не склеивается из кусков.
    static let pagesPerPart = 10

    /// Страницы тетрады с фото на диске, в порядке лекции; слайды — только распознанный текст.
    static func plan(meta: LectureMeta, input: AssemblyInput, paths: LecturePaths,
                     fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
                     textThreshold: Int = 40_000) -> StudyPlan? {
        var pages: [StudyPage] = []
        for (index, page) in meta.notes.enumerated() {
            let image = paths.notePhoto(page.id)
            guard fileExists(image) else { continue }
            let draft = input.notes.first { $0.id == page.id }?.text ?? ""
            pages.append(StudyPage(id: page.id, number: index + 1, image: image, draft: draft))
        }
        if pages.isEmpty {
            // Только слайды: фотографий нет, режем по объёму текста, как в обычной сборке.
            guard !input.slides.isEmpty else { return nil }
            let chunks = AssemblyPlanner.chunk(input.slides, limit: max(textThreshold, 1000))
            return StudyPlan(parts: chunks.map { StudyPart(notes: [], slides: $0) })
        }
        let chunks = chunk(pages, size: pagesPerPart)
        let parts = chunks.enumerated().map { k, notes in
            StudyPart(notes: notes, slides: AssemblyPlanner.slice(input.slides, part: k, of: chunks.count))
        }
        return StudyPlan(parts: parts)
    }

    /// Части по `size` страниц; следующая часть начинается с последней страницы предыдущей (перекрытие в одну).
    static func chunk(_ pages: [StudyPage], size: Int) -> [[StudyPage]] {
        guard !pages.isEmpty else { return [] }
        let size = max(size, 2)
        guard pages.count > size else { return [pages] }
        var result: [[StudyPage]] = []
        var start = 0
        while start < pages.count {
            let end = min(start + size, pages.count)
            result.append(Array(pages[start..<end]))
            if end == pages.count { break }
            start = end - 1
        }
        return result
    }

    /// Таймаут: фото читаются медленнее текста, около полутора минут на страницу, от 3 до 30 минут.
    static func timeout(images: Int, chars: Int) -> TimeInterval {
        min(1800, max(180, 120 + Double(images) * 90 + Double(chars) / 100))
    }
}

extension PromptLibrary {
    static let studyAssemblySystemPrompt = """
    Ты помогаешь студенту сделать из его рукописных конспектов и материалов лекции хороший учебный конспект. \
    Фотографии страниц читай инструментом Read по указанным именам файлов. \
    В ответе выведи только Markdown конспекта, без вступлений и пояснений.
    """

    /// Промпт учебной сборки одной части. Для длинной лекции добавляется пояснение, какая это часть.
    func studyAssemblyPrompt(part: StudyPart, index: Int, of count: Int, subject: String, topic: String) throws -> String {
        let pages = part.notes.map { page -> String in
            var block = "--- Страница \(page.number): ./\(page.image.lastPathComponent) ---"
            if !page.draft.isEmpty { block += "\nЧерновая расшифровка (может содержать ошибки, сверяйся с фото):\n\(page.draft)" }
            return block
        }.joined(separator: "\n\n")
        var prompt = Self.render(try template("assemble-study.md"), values: [
            "предмет": subject,
            "тема": topic,
            "вставка_предмета": subjectInsert(subject),
            "страницы": pages.isEmpty ? "(фотографий нет, материал только в слайдах)" : pages,
            "слайды": part.slides.isEmpty ? "(слайдов нет)" : Self.pagesBlock(part.slides, label: "Слайд"),
        ])
        if count > 1 {
            let span = part.notes.isEmpty ? part.slides.map(\.number) : part.notes.map(\.number)
            let range = span.first.map { "\($0)–\(span.last ?? $0)" } ?? ""
            prompt += "\n\nЭто часть \(index + 1) из \(count) длинной лекции (\(part.notes.isEmpty ? "слайды" : "страницы") \(range)). "
                + "Собери конспект только этой части. Соседние части перекрываются на одну страницу; потом их склеят, "
                + "поэтому ничего не обрывай и не подводи итогов."
        }
        return prompt
    }
}
