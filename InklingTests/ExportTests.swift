import Foundation
import PDFKit
import Testing
@testable import Inkling

@Suite("Экспорт в Anki")
struct AnkiExportTests {
    @Test func headersRowsAndTags() throws {
        var study = try StudyMaterials.parse(Data(StudyFixtures.json().utf8)).get()
        study.flashcards[1].front = "Формула $\\ce{H2O}$"
        var progress = StudyProgress()
        progress.flagged = ["q1"]
        let text = AnkiExporter.export(study, progress: progress, subject: "Общая и неорганическая химия", topic: "ОВР: основы",
                                       includeQuestions: true)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(Array(lines.prefix(3)) == ["#separator:tab", "#html:true", "#tags column:3"])
        let rows = lines.dropFirst(3).filter { !$0.isEmpty }
        #expect(rows.count == 3, "2 карточки + 1 вопрос (q1 помечен ошибочным)")
        #expect(rows.allSatisfy { $0.split(separator: "\t", omittingEmptySubsequences: false).count == 3 })
        #expect(rows[0].hasSuffix("\tОбщая_и_неорганическая_химия::ОВР:_основы"))
        #expect(rows[1].hasPrefix("Формула \\(\\ce{H2O}\\)\t"))
        #expect(rows[2].contains("<b>Решение.</b> Шаг 1. \\(2x=4\\)"))
        #expect(rows[2].hasSuffix(" вопрос"))
        #expect(!AnkiExporter.export(study, progress: progress, subject: "Х", topic: "Т", includeQuestions: false)
            .contains("вопрос"))
    }

    @Test func fieldConversion() {
        #expect(AnkiExporter.field("Инлайн $a_1 < b$ и $$\\int x\\,dx$$") == "Инлайн \\(a_1 &lt; b\\) и \\[\\int x\\,dx\\]")
        #expect(AnkiExporter.field("Цена $5 и $10, \\$3") == "Цена $5 и $10, $3")
        #expect(AnkiExporter.field("строка 1\nстрока\t2") == "строка 1<br>строка 2")
        #expect(AnkiExporter.field("<b>не тег</b> & **жирный** и *курсив*")
            == "&lt;b&gt;не тег&lt;/b&gt; &amp; <b>жирный</b> и <i>курсив</i>")
        #expect(AnkiExporter.field("$x$*$y$") == "\\(x\\)*\\(y\\)")
    }

    @Test func segmentsFollowRendererRules() {
        #expect(AnkiExporter.segments("a $x$ b") == [.text("a "), .math("x", display: false), .text(" b")])
        #expect(AnkiExporter.segments("$ x$") == [.text("$ x$")])
        #expect(AnkiExporter.segments("$$\nx\n$$") == [.math("\nx\n", display: true)])
    }

    @Test func tagsHaveNoSpaces() {
        #expect(AnkiExporter.tag(subject: " Высшая  алгебра ", topic: "Матрицы::ранг") == "Высшая_алгебра::Матрицы:ранг")
    }
}

@Suite("Экспорт в PDF", .timeLimit(.minutes(1)))
@MainActor
struct PDFExportTests {
    @Test func a4WithTextAndFormulas() async throws {
        let dir = try TempDir()
        let url = dir.url.appendingPathComponent("konspekt.pdf")
        let paragraph = "Окислитель принимает электроны, восстановитель отдаёт. Пример: $\\ce{2H2 + O2 -> 2H2O}$.\n\n"
        let markdown = "# Окислительно-восстановительные реакции\n\n" + String(repeating: paragraph, count: 60)
            + "$$\\int_0^1 x\\,dx = \\frac{1}{2}$$\n\nКонец конспекта."
        try await PDFExporter().export(markdown: markdown, title: "ОВР", to: url)

        let document = try #require(PDFDocument(url: url))
        #expect(document.pageCount >= 2, "Длинный конспект разбит на страницы")
        let bounds = try #require(document.page(at: 0)).bounds(for: .mediaBox)
        #expect(abs(bounds.width - 595.28) < 1 && abs(bounds.height - 841.89) < 1, "A4: \(bounds)")
        // Системный шрифт в PDF отдаёт «к» как похожий глиф «ĸ» при извлечении текста; на вид это та же буква.
        let text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined()
            .replacingOccurrences(of: "ĸ", with: "к")
        #expect(text.contains("Окислительно-восстановительные"))
        #expect(text.contains("Конец конспекта"))
        #expect(!text.contains("\\ce{"), "Формулы отрисованы KaTeX, а не напечатаны исходником")
        if let out = ProcessInfo.processInfo.environment["INKLING_PDF_SAMPLE"] {
            try? FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: out))
        }
    }
}

@Suite("Куда сохраняется PDF")
struct ExportLocationTests {
    @Test func pdfNameIsTopicSubjectDate() {
        #expect(ExportLocation.pdfBaseName(subject: "Математический анализ", topic: "пределы функций", date: .d("2026-10-09"))
                == "Пределы функций — Математический анализ — 2026-10-09")
        #expect(ExportLocation.pdfBaseName(subject: "Химия", topic: "ОВР: основы/баланс", date: .d("2026-10-14"))
                == "ОВР- основы-баланс — Химия — 2026-10-14")
    }

    @Test func pdfGoesToSubjectFolderInKonspekty() throws {
        let dir = try TempDir()
        let url = try ExportLocation.pdfURL(baseName: "2026-10-09 — пределы функций", subject: "Математический анализ",
                                            documents: dir.url)
        #expect(url.deletingLastPathComponent().lastPathComponent == "математический анализ")
        #expect(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Конспекты")
        #expect(url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path == dir.url.path)
        #expect(url.lastPathComponent == "2026-10-09 — пределы функций.pdf")
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        // Повтор не падает на уже существующей папке.
        #expect(try ExportLocation.pdfURL(baseName: "x", subject: "Математический анализ", documents: dir.url)
            .lastPathComponent == "x.pdf")
    }

    @Test func subjectFolderIsLowercasedAndSafe() {
        #expect(ExportLocation.subjectFolderName("Общая и неорганическая химия") == "общая и неорганическая химия")
        #expect(ExportLocation.subjectFolderName("ВЫСШАЯ Алгебра") == "высшая алгебра")
        #expect(ExportLocation.subjectFolderName("Физика: механика/МКТ") == FolderNaming.sanitize("физика: механика/мкт"))
    }
}
