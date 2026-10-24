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

@Suite("Шпаргалка")
struct CheatSheetTests {
    private let konspekt = """
    # Конспект

    Химия — Термодинамика

    ## Оглавление

    1. Закон Гесса

    ## 1. Закон Гесса

    Вводный абзац без определения.

    **Закон Гесса (Г. И. Гесс, 1840 г.):** тепловой эффект не зависит от пути.

    $$\\Delta H = \\Delta H_1 + \\Delta H_2$$

    ### 1.1. Следствия

    > **Определение.** Энтальпия образования — тепловой эффект образования 1 моль вещества.

    Просто текст. **Выделенный термин** внутри абзаца.

    ## 2. Примеры решения типовых задач

    **Закон в примере:** не должен попасть.

    $$x = 1$$

    ## Источники

    Книга.
    """

    @Test func collectsDefinitionsAndDisplayFormulasWithoutExamplesAndSources() throws {
        let sheet = try #require(CheatSheet.build(from: konspekt, subject: "Химия", topic: "Термодинамика"))
        #expect(sheet.hasPrefix("# Шпаргалка"))
        #expect(sheet.contains("**Закон Гесса (Г. И. Гесс, 1840 г.):** тепловой эффект не зависит от пути."))
        #expect(sheet.contains("$$\\Delta H = \\Delta H_1 + \\Delta H_2$$"))
        #expect(sheet.contains("**Определение.** Энтальпия образования"))
        #expect(sheet.contains("**1.1. Следствия**"))
        #expect(!sheet.contains("Вводный абзац") && !sheet.contains("Просто текст"))
        #expect(!sheet.contains("не должен попасть") && !sheet.contains("x = 1") && !sheet.contains("Книга."))
        #expect(!sheet.contains("Оглавление"))
    }

    @Test func longDerivationsAndEmptySubsectionsAreLeftOut() throws {
        let text = "## 1. Раздел\n\n### 1.1. Пустой подраздел\n\n### 1.2. Нужный\n\n$$a = b$$\n\n$$= c + d$$\n\n$$x =$$\n\n$$" + String(repeating: "y+", count: 150) + "z$$\n\n$$\\begin{array}{c} 1 \\end{array}$$\n"
        let sheet = try #require(CheatSheet.build(from: text, subject: "С", topic: "Т"))
        #expect(sheet.contains("$$a = b$$") && sheet.contains("**1.2. Нужный**"))
        #expect(!sheet.contains("1.1. Пустой") && !sheet.contains("= c + d") && !sheet.contains("x =$$") && !sheet.contains("y+y+"))
        #expect(!sheet.contains("begin{array}"))
    }

    @Test func emptyWhenNothingToCollectAndIgnoresCodeBlocks() {
        #expect(CheatSheet.build(from: "# К\n\n## 1. Раздел\n\nТолько текст.\n", subject: "С", topic: "Т") == nil)
        #expect(CheatSheet.build(from: "# К\n\n## 1. Р\n\n```\n$$x$$\n```\n", subject: "С", topic: "Т") == nil)
    }

    @Test func cheatSheetFileNameHasPrefix() {
        #expect(ExportLocation.cheatSheetBaseName(subject: "Химия", topic: "тема", date: .d("2026-10-14"))
                == "Шпаргалка — Тема — Химия — 2026-10-14")
    }
}

/// Шпаргалка из реального конспекта (без лимита): `INKLING_CHEAT_FILE` — konspekt.md, `INKLING_CHEAT_OUT` — куда записать.
@Suite("Шпаргалка: реальный файл", .enabled(if: ProcessInfo.processInfo.environment["INKLING_CHEAT_FILE"] != nil))
struct CheatSheetRealFileTests {
    @Test func buildsFromRealKonspekt() throws {
        let environment = ProcessInfo.processInfo.environment
        let text = try String(contentsOfFile: try #require(environment["INKLING_CHEAT_FILE"]), encoding: .utf8)
        let sheet = try #require(CheatSheet.build(from: text, subject: "Предмет", topic: "Тема"))
        print("Шпаргалка: \(sheet.count) символов из \(text.count)")
        if let out = environment["INKLING_CHEAT_OUT"] { try sheet.write(toFile: out, atomically: true, encoding: .utf8) }
    }
}
