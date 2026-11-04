import Foundation
import Testing
@testable import Inkling

@Suite("Ссылки по понятиям")
struct ConceptLinksTests {
    @Test func extractsDefinitionsWithAliasesAndSections() {
        let concepts = ConceptExtractor.concepts(in: """
        ## 2. Матрицы
        **Квадратная матрица** — матрица, у которой строк столько же, сколько столбцов.
        **Определитель (детерминант)** квадратной матрицы называется число…
        **Матрица размера $m \\times n$** — таблица чисел.
        **Условие:** найти определитель.
        **Теорема (о ранге):** ранг не меняется.
        **1. Свойство** — первое.
        **Жирное слово** без определения.
        **Суммой** матриц называется матрица…
        **б. м.** — бесконечно малая.
        **СЛУ** — система линейных уравнений.
        """)
        #expect(concepts.map(\.name) == ["Квадратная матрица", "Определитель", "детерминант", "Матрица размера", "СЛУ"])
        #expect(concepts[0].stems == ["квадратн", "матриц"])
        #expect(concepts.allSatisfy { $0.anchor == "sec-1" && $0.section == "2. Матрицы" })
    }

    private func lecture(_ topic: String, _ date: String) -> LectureRecord {
        LectureRecord(meta: LectureMeta(subject: "Алгебра", topic: topic, date: .d(date)), folder: URL(filePath: "/tmp/\(topic)"))
    }

    @Test func linksFirstDefinitionAndRanksRelated() {
        let matrices = lecture("Матрицы", "2026-10-13"), minors = lecture("Миноры", "2026-10-20")
        let slae = lecture("СЛУ", "2026-10-23"), other = lecture("Пространства", "2026-10-30")
        let texts: [UUID: KonspektSearchText] = [
            matrices.id: KonspektSearchText(markdown: """
            ## 1. Виды
            **Квадратная матрица** — матрица n×n.
            **Определение** — общее слово, определено везде.
            """),
            minors.id: KonspektSearchText(markdown: """
            ## 1. Миноры
            **Минор** — определитель подматрицы квадратной матрицы.
            **Определение** — общее слово.
            """),
            slae.id: KonspektSearchText(markdown: """
            **Определение** — общее слово.
            Для квадратных матриц считаем миноры и решаем систему.
            """),
            other.id: KonspektSearchText(markdown: "Без общих понятий."),
        ]
        let lectures = [other, slae, minors, matrices]
        let links = ConceptLinks.build(for: slae.id, lectures: lectures, texts: texts)

        #expect(links.links.map(\.stems) == [["квадратн", "матриц"], ["минор"]])
        #expect(links.links[0].lecture == matrices.id)
        #expect(links.links[0].anchor == "sec-1")
        #expect(links.links[0].title == "Определено в лекции «Матрицы», раздел «1. Виды»")
        #expect(!links.links.contains { $0.stems == ["определен"] }, "понятие из трёх лекций — общее")

        #expect(links.related.map(\.title) == ["Матрицы", "Миноры"])
        #expect(links.related[1].definedThere == ["Минор"])
        let fromMinors = ConceptLinks.build(for: minors.id, lectures: lectures, texts: texts)
        #expect(fromMinors.related.first { $0.lecture == slae.id }?.definedHere == ["Минор"], "на неё ссылаются отсюда")
        #expect(ConceptLinks.build(for: other.id, lectures: lectures, texts: texts) == ConceptLinks())
    }

    @Test func ownDefinitionIsNotLinkedAway() {
        let a = lecture("А", "2026-10-01"), b = lecture("Б", "2026-10-02")
        let texts: [UUID: KonspektSearchText] = [
            a.id: KonspektSearchText(markdown: "**Предел последовательности** — число."),
            b.id: KonspektSearchText(markdown: "**Предел последовательности** — снова. Предел последовательности ищем."),
        ]
        #expect(ConceptLinks.build(for: b.id, lectures: [a, b], texts: texts).links.isEmpty)
    }

    @Test func phraseMatchingNeedsConsecutiveWords() {
        let text = KonspektSearchText(markdown: "Квадратной матрицы нет, есть матрица квадратная.")
        #expect(text.contains(["квадратн", "матриц"]))
        #expect(!KonspektSearchText(markdown: "матрица квадратная").contains(["квадратн", "матриц"]))
    }

    @Test func anchorsAreParsedOnlyAsSections() throws {
        let id = UUID()
        #expect(NotesWebView.Coordinator.anchor(try #require(URL(string: "inkling-lecture://\(id)#sec-12"))) == "sec-12")
        #expect(NotesWebView.Coordinator.anchor(try #require(URL(string: "inkling-lecture://\(id)#x\"onload"))) == nil)
        #expect(NotesWebView.Coordinator.anchor(try #require(URL(string: "inkling-lecture://\(id)"))) == nil)
    }
}
