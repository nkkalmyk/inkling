import Foundation
import Testing
@testable import Inkling

struct MarkdownExporterTests {
    private let date = CalendarDate(year: 2026, month: 10, day: 13)

    @Test func addsFrontMatter() {
        let document = MarkdownExporter.document(konspekt: "# Матрицы\n\nТекст", subject: "Высшая алгебра",
                                                 topic: "Матрицы", date: date)
        #expect(document == """
            ---
            title: "Матрицы"
            subject: "Высшая алгебра"
            date: 2026-10-13
            source: Inkling
            ---

            # Матрицы

            Текст

            """)
    }

    @Test func addsTitleWhenKonspektHasNone() {
        let document = MarkdownExporter.document(konspekt: "## Раздел\nТекст", subject: "Химия", topic: "Электрохимия",
                                                 date: date)
        #expect(document.contains("---\n\n# Электрохимия\n\n## Раздел\nТекст\n"))
    }

    @Test func escapesQuotesInYAML() {
        let document = MarkdownExporter.document(konspekt: "# T", subject: "Предмет \"А\"", topic: "T", date: date)
        #expect(document.contains(#"subject: "Предмет \"А\"""#))
    }

    @Test func collapsesBlankLines() {
        #expect(MarkdownExporter.normalized("\n\nА\n \n\t\n\n\nБ\n\n") == "А\n\nБ")
    }

    @Test func keepsMarkdownLineBreaks() {
        #expect(MarkdownExporter.normalized("строка  \nследующая") == "строка  \nследующая")
    }

    @Test func keepsCodeBlocksVerbatim() {
        let code = "```\nа\n\n\n  \nб\n```"
        #expect(MarkdownExporter.normalized("Текст\n\n\n" + code + "\n\n\nКонец") == "Текст\n\n" + code + "\n\nКонец")
    }
}
