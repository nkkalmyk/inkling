import Foundation
import Observation

/// Фрагмент конспекта под строкой лекции в поиске: найденные слова выделяются.
struct KonspektSnippet: Equatable, Sendable {
    struct Part: Equatable, Sendable {
        var text: String
        var isMatch: Bool
    }

    var parts: [Part]

    var text: String { parts.map(\.text).joined() }
}

/// Текст конспекта для поиска: без разметки и формул, слова целиком (нижний регистр, `ё → е`) с местом в тексте,
/// чтобы показать фрагмент вокруг найденного. Усечение `RussianNormalizer` до 6 букв здесь слишком грубое:
/// «определители» находили бы «определение».
struct KonspektSearchText: Sendable {
    private struct Word: Sendable {
        var token: String
        var range: Range<String.Index>
    }

    let plain: String
    private let words: [Word]
    /// Номера слов по первым двум буквам: `contains` проверяет только места, где может начаться понятие, а не весь текст.
    /// Расчёт ссылок понятий на предмете из 30 лекций шёл больше секунды на главном потоке (аудит 2026-11, D1.2).
    private let positions: [Substring: [Int]]
    /// Понятия, определённые в этом конспекте (`ConceptExtractor`), для ссылок между лекциями.
    let concepts: [Concept]

    init(markdown: String) {
        let plain = Self.plainText(markdown)
        self.plain = plain
        concepts = ConceptExtractor.concepts(in: markdown)
        var words: [Word] = []
        var start: String.Index?
        var index = plain.startIndex
        func flush(_ end: String.Index) {
            guard let from = start else { return }
            start = nil
            words.append(Word(token: Self.normalized(plain[from..<end]), range: from..<end))
        }
        while index < plain.endIndex {
            let character = plain[index]
            if character.isLetter || character.isNumber {
                if start == nil { start = index }
            } else {
                flush(index)
            }
            index = plain.index(after: index)
        }
        flush(plain.endIndex)
        self.words = words
        var positions: [Substring: [Int]] = [:]
        for (offset, word) in words.enumerated() { positions[word.token.prefix(2), default: []].append(offset) }
        self.positions = positions
    }

    /// Основы слов запроса (`queryStems`) для `snippet(for:)`: без служебных слов и повторов, окончание отрезано
    /// («пределы» → «предел», «определители» → «определител»), чтобы находились другие формы слова.
    static func queryStems(_ query: String) -> [String] {
        var seen = Set<String>()
        return query.split { !$0.isLetter && !$0.isNumber }.compactMap { piece -> String? in
            let word = normalized(piece)
            guard word.count >= RussianNormalizer.minimumLength, !RussianNormalizer.stopwords.contains(word) else { return nil }
            let stem = stem(Substring(word))
            return seen.insert(stem).inserted ? stem : nil
        }
    }

    /// Основа слова: нижний регистр, `ё → е`, отрезаны гласные окончания, но не короче четырёх букв.
    /// Та же основа у понятий (`ConceptExtractor`); в `render.js` слова текста приводятся так же (`normalizeWord`).
    static func stem(_ word: Substring) -> String {
        var stem = Substring(normalized(word))
        while stem.count > 4, let last = stem.last, "аеиоуыэюяйь".contains(last) { stem = stem.dropLast() }
        return String(stem)
    }

    static func normalized(_ word: Substring) -> String {
        word.lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    /// Есть ли в тексте подряд слова с этими основами (понятие из нескольких слов).
    func contains(_ stems: [String]) -> Bool {
        guard let first = stems.first, words.count >= stems.count else { return false }
        func matches(at start: Int) -> Bool {
            start + stems.count <= words.count && stems.indices.allSatisfy { words[start + $0].token.hasPrefix(stems[$0]) }
        }
        // Слово начинается с основы только при тех же первых двух буквах; короче двух — проверяем всё.
        guard first.count >= 2 else { return (0...(words.count - stems.count)).contains(where: matches) }
        return (positions[first.prefix(2)] ?? []).contains(where: matches)
    }

    /// Фрагмент вокруг первого найденного слова, если в конспекте есть все слова запроса.
    /// Основа из запроса совпадает с началом слова текста: «пред» находит «предел» уже при наборе.
    func snippet(for query: [String], before: Int = 2, after: Int = 12) -> KonspektSnippet? {
        guard !query.isEmpty else { return nil }
        func matches(_ word: Word) -> Bool { query.contains { word.token.hasPrefix($0) } }
        for token in query where !words.contains(where: { $0.token.hasPrefix(token) }) { return nil }
        guard let first = words.firstIndex(where: matches) else { return nil }
        let window = words[max(0, first - before)...min(words.count - 1, first + after)]
        guard let lower = window.first?.range.lowerBound, let upper = window.last?.range.upperBound else { return nil }

        var parts: [KonspektSnippet.Part] = []
        if lower > plain.startIndex { parts.append(.init(text: "…", isMatch: false)) }
        var cursor = lower
        for word in window where matches(word) {
            if cursor < word.range.lowerBound {
                parts.append(.init(text: String(plain[cursor..<word.range.lowerBound]), isMatch: false))
            }
            parts.append(.init(text: String(plain[word.range]), isMatch: true))
            cursor = word.range.upperBound
        }
        if cursor < upper { parts.append(.init(text: String(plain[cursor..<upper]), isMatch: false)) }
        if upper < plain.endIndex { parts.append(.init(text: "…", isMatch: false)) }
        return KonspektSnippet(parts: parts)
    }

    /// Текст без Markdown: формулы — знаком «[…]» (без букв, чтобы сам не находился), блоки кода (рисунки `diagram.js`) и пометки
    /// распознавания убираются, догадка `[?слово]` остаётся словом.
    static func plainText(_ markdown: String) -> String {
        var text = markdown
        let replacements: [(String, String)] = [
            (#"(?s)```.*?```"#, " "),
            (#"(?s)\$\$.+?\$\$"#, " […] "),
            (#"(?<!\\)\$(?!\s)[^$\n]+?(?<!\s)\$"#, " […] "),
            (#"\[неразборчиво\]"#, " "),
            (#"\[\?([^\]]*)\]"#, "$1"),
            (#"<[^>\n]+>"#, " "),
            (#"!?\[([^\]]*)\]\([^)]*\)"#, "$1"),
            (#"(?m)^\s{0,3}(#{1,6}|>|[-*+]|\d+[.)])\s+"#, ""),
            (#"(?m)^\s*([-*_|:]\s*){3,}$"#, " "),
            (#"[*_`|]+"#, " "),
            (#"\s+"#, " "),
        ]
        for (pattern, template) in replacements {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}

/// Поиск по тексту конспектов (SPEC, раздел 13): индекс в памяти, файлы читаются в фоне и только у изменившихся
/// лекций. Список лекций сам файлы не читает: в iCloud они могут быть выгружены. Выгруженный конспект
/// пропускается, пока не скачается (тогда сменится и ключ лекции).
@MainActor
@Observable
final class KonspektSearchCenter {
    private(set) var texts: [UUID: KonspektSearchText] = [:] { didSet { textsVersion &+= 1 } }
    @ObservationIgnored private var keys: [UUID: String] = [:]
    /// Меняется при каждом изменении `texts`: по нему кэш связей понятий понимает, что пора пересчитать.
    @ObservationIgnored private var textsVersion = 0
    @ObservationIgnored private var linksCache: [UUID: (key: Int, links: ConceptLinks)] = [:]

    /// От чего зависит текст конспекта: правка в окне меняет `konspektRevision`, сборка — `updatedAt`.
    nonisolated static func key(_ lecture: LectureRecord, revision: Int) -> String? {
        guard let info = lecture.meta.konspekt else { return nil }
        return "\(revision)|\(info.updatedAt.timeIntervalSince1970)|\(lecture.folder.path)"
    }

    func refresh(_ lectures: [LectureRecord], revisions: [UUID: Int]) {
        let alive = Set(lectures.map(\.id))
        for id in texts.keys where !alive.contains(id) { texts[id] = nil }
        for id in keys.keys where !alive.contains(id) { keys[id] = nil }
        for lecture in lectures {
            let id = lecture.id
            guard let key = Self.key(lecture, revision: revisions[id] ?? 0) else {
                texts[id] = nil
                keys[id] = nil
                continue
            }
            guard keys[id] != key else { continue }
            keys[id] = key
            let folder = lecture.folder
            Task {
                let text = await Self.load(folder)
                guard keys[id] == key else { return }
                if let text { texts[id] = text } else { keys[id] = nil }
            }
        }
    }

    /// Ссылки по понятиям для конспекта лекции среди лекций её предмета (`ConceptLinks`).
    /// Вызывается из `body` конспекта при каждой перерисовке, поэтому результат кэшируется: пересчёт — только когда
    /// изменились конспекты или лекции предмета (D1.2, аудит 2026-11).
    func conceptLinks(for id: UUID, among lectures: [LectureRecord]) -> ConceptLinks {
        var hasher = Hasher()
        hasher.combine(textsVersion)
        for lecture in lectures {
            hasher.combine(lecture.id)
            hasher.combine(lecture.meta.topic)
            hasher.combine(lecture.meta.date)
        }
        let key = hasher.finalize()
        if let cached = linksCache[id], cached.key == key { return cached.links }
        let links = ConceptLinks.build(for: id, lectures: lectures, texts: texts)
        linksCache[id] = (key, links)
        return links
    }

    /// Фрагменты лекций, в конспекте которых есть все слова запроса.
    func snippets(for query: String) -> [UUID: KonspektSnippet] {
        let tokens = KonspektSearchText.queryStems(query)
        guard !tokens.isEmpty else { return [:] }
        return texts.compactMapValues { $0.snippet(for: tokens) }
    }

    @concurrent
    private static func load(_ folder: URL) async -> KonspektSearchText? {
        let store = KonspektStore(folder: folder)
        guard ICloud.availability(of: store.url) == .local, let markdown = store.read() else { return nil }
        return KonspektSearchText(markdown: markdown)
    }
}
