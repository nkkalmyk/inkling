import Foundation
import Testing
@testable import Inkling

@Suite("Скопировать для чата")
struct ChatHandoffTests {
    @Test func bundledTemplateFillsSubjectTopicAndKonspekt() throws {
        let dir = try TempDir()
        let template = try PromptLibrary(root: dir.url).template(ExportController.chatTemplate)
        let konspekt = "\n## 1. Предел\n**Предел** — число $a$, для которого $\\lim x_n = a$ и {тема} не трогаем.\n\n"
        let text = ExportController.chatPrompt(template: template, konspekt: konspekt, subject: "Математический анализ",
                                               topic: "Пределы")
        #expect(text.contains("«Математический анализ»"))
        #expect(text.contains("«Пределы»"))
        #expect(text.hasSuffix("$\\lim x_n = a$ и {тема} не трогаем."), "конспект в конце, формулы и фигурные скобки как есть")
        #expect(!text.contains("{конспект}") && !text.contains("{предмет}"))
    }
}
