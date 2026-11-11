import Foundation
import Testing
@testable import Inkling

@Suite("Поиск по тексту конспектов")
struct KonspektSearchTests {
    private let konspekt = """
    # Конспект

    ## 2. Предел последовательности

    **Предел последовательности** — число $a$, такое что для любого $\\varepsilon>0$ найдётся номер $N$.

    $$
    \\lim_{n\\to\\infty} \\frac{1}{n} = 0
    $$

    - Сходящаяся последовательность ограничена.
    - [?Теорема] Вейерштрасса о монотонной [неразборчиво] последовательности.

    ```diagram
    предел скрытый в рисунке
    ```
    """

    private func snippet(_ query: String, in markdown: String? = nil) -> KonspektSnippet? {
        KonspektSearchText(markdown: markdown ?? konspekt).snippet(for: KonspektSearchText.queryStems(query))
    }

    @Test func plainTextDropsMarkupFormulasAndMarks() {
        let plain = KonspektSearchText.plainText(konspekt)
        #expect(!plain.contains("$"))
        #expect(!plain.contains("**"))
        #expect(!plain.contains("#"))
        #expect(!plain.contains("неразборчиво"))
        #expect(!plain.contains("рисунке"), "блоки рисунков не ищутся")
        #expect(plain.contains("Теорема Вейерштрасса"), "догадка [?слово] остаётся словом")
        #expect(plain.contains("[…]"))
        #expect(snippet("формула") == nil, "заглушка формулы сама не находится")
    }

    @Test func wordFormsAndPrefixesMatch() {
        #expect(snippet("пределы") != nil, "другая форма слова")
        #expect(snippet("ОГРАНИЧЕНА") != nil)
        #expect(snippet("определители", in: "Определение предела") == nil, "основа, а не первые шесть букв")
        #expect(snippet("определители", in: "Свойства определителя") != nil)
        #expect(snippet("вейер") != nil, "начало слова при наборе")
        #expect(snippet("сходимость ряда") == nil, "нужны все слова запроса")
        #expect(snippet("и что") == nil, "служебные слова не ищутся")
        #expect(snippet("рисунке") == nil)
    }

    @Test func snippetHighlightsMatchesAroundFirstHit() throws {
        let found = try #require(snippet("вейерштрасса монотонной"))
        #expect(found.parts.filter(\.isMatch).map(\.text) == ["Вейерштрасса", "монотонной"])
        #expect(found.text.hasPrefix("…"))
        #expect(found.parts[1].text.split(separator: " ").count <= 3, "до найденного — не больше двух слов")
        #expect(!found.text.contains("Конспект"), "фрагмент — окно вокруг слова, а не весь текст")
    }

    @Test func queryStemsCutEndingsOnly() {
        #expect(KonspektSearchText.queryStems("Пределы и определители, пределы") == ["предел", "определител"])
        #expect(KonspektSearchText.queryStems("ёлка") == ["елка"], "ё → е; основа не короче четырёх букв")
        #expect(KonspektSearchText.queryStems("ряд") == ["ряд"], "короткое слово не режется")
    }

    @Test func shortTextHasNoEllipsis() throws {
        let found = try #require(snippet("матрица", in: "Обратная матрица существует"))
        #expect(found.text == "Обратная матрица существует")
        #expect(found.parts.map(\.isMatch) == [false, true, false])
    }

    @Test func keyFollowsKonspektRevision() {
        var meta = LectureMeta(subject: "Алгебра", topic: "Матрицы", date: .d("2026-10-13"))
        let folder = URL(filePath: "/tmp/lecture")
        #expect(KonspektSearchCenter.key(LectureRecord(meta: meta, folder: folder), revision: 0) == nil, "нет конспекта")
        meta.konspekt = ArtifactInfo(createdAt: .now, updatedAt: Date(timeIntervalSince1970: 100), inputHash: "h")
        let record = LectureRecord(meta: meta, folder: folder)
        #expect(KonspektSearchCenter.key(record, revision: 0) != KonspektSearchCenter.key(record, revision: 1))
    }

    @MainActor
    @Test func centerReadsLocalKonspektsInBackground() async throws {
        let dir = try TempDir()
        var meta = LectureMeta(subject: "Алгебра", topic: "Матрицы", date: .d("2026-10-13"))
        meta.konspekt = ArtifactInfo(createdAt: .now, updatedAt: .now, inputHash: "h")
        try Data("Определитель обратной матрицы".utf8).write(to: dir.url.appendingPathComponent("konspekt.md"))
        let center = KonspektSearchCenter()
        center.refresh([LectureRecord(meta: meta, folder: dir.url)], revisions: [:])
        for _ in 0..<100 where center.texts.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(center.snippets(for: "определители")[meta.id] != nil)
        center.refresh([], revisions: [:])
        #expect(center.texts.isEmpty, "удалённая лекция уходит из индекса")
    }
}

/// D1.2 (аудит 2026-11): `contains` ищет понятие только с мест, где слово начинается с тех же двух букв.
/// Ответ должен совпадать с прежним полным перебором.
@Suite("Поиск понятий в тексте: индекс по началу слова")
struct ConceptContainsTests {
    private static func bruteForce(_ text: String, _ stems: [String]) -> Bool {
        let words = text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !stems.isEmpty, words.count >= stems.count else { return false }
        return (0...(words.count - stems.count)).contains { start in
            stems.indices.allSatisfy { words[start + $0].hasPrefix(stems[$0]) }
        }
    }

    @Test func matchesBruteForce() {
        let text = "Квадратная матрица называется вырожденной, если её определитель равен нулю. "
            + "Ранг матрицы — наибольший порядок ненулевого минора. Ёмкость и 2x2 матрица А."
        let search = KonspektSearchText(markdown: text)
        let cases: [[String]] = [["матриц"], ["квадратн", "матриц"], ["определител", "равен"], ["ранг", "матриц"],
                                 ["емкост"], ["2x2"], ["а"], ["м"], ["матриц", "назыв", "вырожд"], ["минор", "ранг"],
                                 ["нул"], ["xyz"], [], ["определител", "матриц"]]
        for stems in cases {
            #expect(search.contains(stems) == Self.bruteForce(text, stems), "\(stems)")
        }
    }
}
