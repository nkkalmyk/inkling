import Testing
@testable import Inkling

@Suite("Яркая кнопка тулбара лекции")
struct LectureProminentButtonTests {
    private func choose(_ primary: LecturePrimaryAction?, pdf: Bool = true, known: Bool = true,
                        tab: LectureTab = .notes) -> LectureProminentButton {
        LectureProminentButton.choose(primary: primary, pdfAvailable: pdf, summaryKnown: known, tab: tab)
    }

    @Test func recognizeAndAssembleWinOverPDF() {
        #expect(choose(.recognize(pages: ["p1"])) == .primary)
        #expect(choose(.assemble(rebuild: true)) == .primary, "устаревший конспект сначала пересобирают")
        #expect(choose(.assemble(rebuild: false), pdf: false) == .primary)
    }

    @Test func prepareStudyYieldsToPDFOutsideStudy() {
        for tab in [LectureTab.sources, .notes] {
            #expect(choose(.prepareStudy(rebuild: false), tab: tab) == .pdf)
        }
        for tab in LectureTab.studyTabs {
            #expect(choose(.prepareStudy(rebuild: false), tab: tab) == .primary)
        }
        #expect(choose(.prepareStudy(rebuild: true), pdf: false) == .primary, "пока PDF недоступен — следующий шаг")
    }

    @Test func freshKonspektWithoutNextStep() {
        #expect(choose(nil) == .pdf)
        #expect(choose(nil, tab: .flashcards) == .pdf)
        #expect(choose(nil, pdf: false) == .none, "конспекта нет или он пересобирается")
        #expect(choose(nil, known: false) == .none, "сводка по текстам не готова — не мигаем")
    }
}
