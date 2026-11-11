import Foundation

/// Понятие, определённое в конспекте: жирное начало абзаца, за которым идёт «—» или «называется»
/// (формат учебного конспекта, SPEC, раздел 13). Из определения «**Определитель (детерминант)** —» выходят два понятия.
struct Concept: Equatable, Sendable {
    /// Название, как в определении, без формул.
    var name: String
    /// Основы слов (`KonspektSearchText.stem`): по ним понятие ищется в других конспектах.
    var stems: [String]
    /// Якорь раздела, как его ставит `render.js` (`sec-N` по порядку заголовков h1–h3); `nil` — до первого заголовка.
    var anchor: String?
    /// Заголовок раздела без решёток.
    var section: String?

    var key: String { stems.joined(separator: " ") }
}

enum ConceptExtractor {
    /// Служебные начала абзацев учебного конспекта: это не понятия.
    private static let skippedPrefixes = ["условие", "решение", "ответ", "замечани", "доказательств", "пример", "следстви",
                                          "случай", "вычислени", "общий случай", "итог", "важно", "шаг", "способ", "задача",
                                          "правило", "теорема", "лемма", "свойств"]

    static func concepts(in markdown: String) -> [Concept] {
        var result: [Concept] = []
        var headings = 0
        var section: String?
        var fence = MarkdownFence()
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if fence.consume(line) || fence.isInside { continue }
            if let heading = headingText(line) {
                headings += 1
                section = heading
                continue
            }
            guard line.hasPrefix("**"), let close = line.dropFirst(2).range(of: "**") else { continue }
            let head = line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound]
            let tail = line[close.upperBound...].prefix(60)
            let trimmedTail = tail.trimmingCharacters(in: .whitespaces)
            guard trimmedTail.hasPrefix("—") || trimmedTail.hasPrefix("–") || trimmedTail.hasPrefix("- ")
                    || tail.contains("называ") else { continue }
            let anchor = headings > 0 ? "sec-\(headings)" : nil
            for name in names(String(head)) {
                guard let stems = stems(name) else { continue }
                result.append(Concept(name: name, stems: stems, anchor: anchor, section: section))
            }
        }
        return result
    }

    /// Текст заголовка h1–h3: `render.js` ставит якоря только им и по порядку.
    static func headingText(_ line: Substring) -> String? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...3).contains(hashes.count), line.dropFirst(hashes.count).first == " " else { return nil }
        return line.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
    }

    /// Названия из жирного начала: без формул и знаков в конце; синоним в скобках — второе название.
    private static func names(_ head: String) -> [String] {
        let cleaned = head.replacingOccurrences(of: #"\$[^$]*\$"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " :.—–-"))
        let lower = cleaned.lowercased()
        guard let first = lower.first, !first.isNumber, !skippedPrefixes.contains(where: lower.hasPrefix) else { return [] }
        if let open = cleaned.firstIndex(of: "("), cleaned.hasSuffix(")") {
            let main = cleaned[..<open].trimmingCharacters(in: .whitespaces)
            let alias = cleaned[cleaned.index(after: open)..<cleaned.index(before: cleaned.endIndex)]
                .trimmingCharacters(in: .whitespaces)
            return [main, alias].filter { !$0.isEmpty }
        }
        return [cleaned]
    }

    /// Основы слов названия или `nil`, если понятие слишком общее для ссылки: однобуквенные слова («б. м.»),
    /// длиннее четырёх слов, одно короткое слово («Суммой» → «сумм»). Сокращения капслоком («СЛУ») остаются.
    private static func stems(_ name: String) -> [String]? {
        let words = name.split { !$0.isLetter && !$0.isNumber }
        guard (1...4).contains(words.count), words.allSatisfy({ $0.count >= 2 }) else { return nil }
        let stems = words.map { KonspektSearchText.stem($0) }
        if words.count == 1, stems[0].count < 5, !(words[0].count >= 2 && words[0].allSatisfy(\.isUppercase)) {
            return nil
        }
        return stems
    }
}

/// Связи конспекта с другими лекциями предмета по понятиям (SPEC, раздел 13): первое упоминание понятия,
/// определённого в другой лекции, становится ссылкой, а внизу — до пяти «связанных лекций».
/// Считается при показе и в `konspekt.md` не пишется.
struct ConceptLinks: Equatable, Sendable, Encodable {
    struct Link: Equatable, Sendable, Encodable {
        var stems: [String]
        var lecture: UUID
        var anchor: String?
        /// Подсказка: где определено.
        var title: String
    }

    struct Related: Equatable, Sendable, Encodable {
        var lecture: UUID
        var title: String
        /// Понятия той лекции, которые встречаются здесь.
        var definedThere: [String]
        /// Понятия этой лекции, которые встречаются там.
        var definedHere: [String]
    }

    var links: [Link] = []
    var related: [Related] = []

    /// Понятие, определённое больше чем в стольких лекциях, общее для предмета: ссылкой не становится.
    static let maxDefinitions = 2
    static let maxRelated = 5

    /// `lectures` — лекции предмета, `texts` — их разобранные конспекты (у лекций без конспекта текста нет).
    static func build(for id: UUID, lectures: [LectureRecord], texts: [UUID: KonspektSearchText]) -> ConceptLinks {
        guard let here = texts[id] else { return ConceptLinks() }
        let ordered = lectures.filter { $0.id != id && texts[$0.id] != nil }
            .sorted { ($0.meta.date, $0.meta.topic) < ($1.meta.date, $1.meta.topic) }
        var definedIn: [String: Int] = [:]
        for lecture in lectures {
            for key in Set((texts[lecture.id]?.concepts ?? []).map(\.key)) { definedIn[key, default: 0] += 1 }
        }
        func eligible(_ concepts: [Concept]) -> [Concept] {
            var seen = Set<String>()
            return concepts.filter { (definedIn[$0.key] ?? 0) <= maxDefinitions && seen.insert($0.key).inserted }
        }
        let ownKeys = Set(here.concepts.map(\.key))
        let own = eligible(here.concepts)

        var result = ConceptLinks()
        var linked = Set<String>()
        for lecture in ordered {
            guard let there = texts[lecture.id] else { continue }
            let foreign = eligible(there.concepts).filter { !ownKeys.contains($0.key) }
            let usedHere = foreign.filter { here.contains($0.stems) }
            for concept in usedHere where linked.insert(concept.key).inserted {
                let section = concept.section.map { ", раздел «\($0)»" } ?? ""
                result.links.append(Link(stems: concept.stems, lecture: lecture.id, anchor: concept.anchor,
                                         title: "Определено в лекции «\(lecture.meta.topic)»\(section)"))
            }
            let usedThere = own.filter { there.contains($0.stems) }
            if !usedHere.isEmpty || !usedThere.isEmpty {
                result.related.append(Related(lecture: lecture.id, title: lecture.meta.topic,
                                              definedThere: usedHere.map(\.name), definedHere: usedThere.map(\.name)))
            }
        }
        result.related = Array(result.related.enumerated()
            .sorted { lhs, rhs in
                let a = lhs.element.definedThere.count + lhs.element.definedHere.count
                let b = rhs.element.definedThere.count + rhs.element.definedHere.count
                return a != b ? a > b : lhs.offset < rhs.offset
            }
            .prefix(maxRelated).map(\.element))
        return result
    }
}
