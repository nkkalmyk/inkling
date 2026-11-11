import CoreGraphics
import Foundation
import PDFKit
import Testing
import WebKit
@testable import Inkling

/// Замеры скорости (аудит 2026-11, этап 5). Порогов по времени нет: в обычном прогоне проверяются только
/// детерминированные счётчики, а время печатается строкой «ЗАМЕР …» при `TEST_RUNNER_INKLING_PERF=1`.
/// Цифры «до/после» — в `docs/AUDIT-2026-11-fixlist.md`.
@Suite("Скорость: замеры")
@MainActor
struct PerformanceTests {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["INKLING_PERF"] == "1"

    private static func report(_ name: String, _ duration: Duration) {
        let ms = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        print("ЗАМЕР \(name): \(String(format: "%.1f", ms)) мс")
    }

    private static func median(_ runs: Int, _ body: () async throws -> Void) async rethrows -> Duration {
        var samples: [Duration] = []
        for _ in 0..<runs {
            let clock = ContinuousClock()
            let start = clock.now
            try await body()
            samples.append(clock.now - start)
        }
        return samples.sorted()[runs / 2]
    }

    /// Длинный учебный конспект: разделы с формулами, всего около 500 формул.
    static func longKonspekt(sections: Int = 50) -> String {
        var text = "# Конспект\n\n## Оглавление\n\n"
        for i in 1...sections {
            text += "## \(i). Раздел \(i)\n\n**Определение \(i)** — величина $x_{\(i)} = \\frac{a_{\(i)}}{b}$ "
            text += "и $\\ce{H2SO4 + 2NaOH -> Na2SO4 + 2H2O}$.\n\n"
            for j in 1...8 { text += "Шаг \(j): $\\int_0^{\(j)} x^{\(i)}\\,dx = \\frac{\(j)^{\(i + 1)}}{\(i + 1)}$, далее текст.\n" }
            text += "\n$$\\sum_{k=1}^{n} k^{\(i)} \\approx \\frac{n^{\(i + 1)}}{\(i + 1)}$$\n\n"
        }
        return text
    }

    // MARK: Рендер конспекта

    /// Открытие конспекта: текст и ссылки понятий приходят двумя вызовами (`NotesWebView`). Разметка должна
    /// разбираться один раз; раньше второй вызов заново гонял markdown-it и KaTeX по всему документу.
    @Test(.timeLimit(.minutes(1)))
    func konspektOpenRendersMarkdownOnce() async throws {
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 1000))
        let loader = PageLoader()
        try await loader.load(view)
        _ = try await view.evaluateJavaScript("""
            window.__renders = 0; var original = InklingRender.toHTML;
            InklingRender.toHTML = function (m) { window.__renders++; return original(m); }; 1
            """)
        let markdown = String(decoding: try JSONEncoder().encode(Self.longKonspekt()), as: UTF8.self)
        let concepts = #"{"links":[{"stems":["величин"],"lecture":"00000000-0000-0000-0000-000000000001","anchor":"x","title":"Т"}],"related":[]}"#
        let elapsed = try await view.evaluateJavaScript("""
            (function () {
              var t = performance.now();
              window.inklingShow(\(markdown));
              window.inklingSetConcepts(\(concepts));
              return performance.now() - t;
            })()
            """) as? Double ?? -1
        #expect(try await view.evaluateJavaScript("window.__renders") as? Int == 1)
        #expect(try await view.evaluateJavaScript("document.querySelectorAll('.katex').length") as? Int ?? 0 > 400)
        if Self.enabled { print("ЗАМЕР открытие длинного конспекта (текст + понятия): \(String(format: "%.1f", elapsed)) мс") }
    }

    // MARK: Библиотека

    @Test(.enabled(if: PerformanceTests.enabled))
    func libraryOpenWith300Lectures() async throws {
        let dir = try TempDir()
        let root = dir.url.appendingPathComponent("Inkling")
        let store = LibraryStore(root: root, trasher: try FakeTrasher(bin: dir.url.appendingPathComponent("_bin")))
        try store.bootstrap()
        for i in 0..<300 {
            _ = try store.createLecture(subject: ["Высшая алгебра", "Математический анализ", "Химия"][i % 3],
                                        topic: "Лекция \(i)", date: .d("2026-10-14"))
        }
        let duration = await Self.median(5) {
            let library = Library(root: root, trasher: try! FakeTrasher(bin: dir.url.appendingPathComponent("_bin2")))
            library.open(root: root)
        }
        Self.report("Library.open, 300 лекций", duration)
    }

    // MARK: Связи понятий

    /// `ConceptLinks.build` считается при каждом показе конспекта (в `body`). Предмет из 30 лекций,
    /// в каждой 40 определений и ~3000 слов.
    @Test(.enabled(if: PerformanceTests.enabled))
    func conceptLinksForSubject() async throws {
        let lexicon = ["матрица", "определитель", "ранг", "базис", "вектор", "оператор", "собственный", "линейный",
                       "пространство", "отображение", "уравнение", "система", "решение", "преобразование"]
        var lectures: [LectureRecord] = []
        var texts: [UUID: KonspektSearchText] = [:]
        for l in 0..<30 {
            var markdown = "# Лекция \(l)\n\n"
            for c in 0..<40 {
                markdown += "## \(c + 1). Раздел\n\n**\(lexicon[(l + c) % lexicon.count].capitalized) \(lexicon[(c * 3 + l) % lexicon.count]) \(l)-\(c)** — "
                markdown += (0..<70).map { lexicon[($0 * 5 + c + l) % lexicon.count] }.joined(separator: " ") + ".\n\n"
            }
            var meta = LectureMeta(subject: "Высшая алгебра", topic: "Лекция \(l)", date: .d("2026-10-14"), now: Date())
            meta.konspekt = ArtifactInfo(createdAt: Date(), updatedAt: Date(), inputHash: "x")
            let record = LectureRecord(meta: meta, folder: URL(fileURLWithPath: "/tmp/\(l)"))
            lectures.append(record)
            texts[record.id] = KonspektSearchText(markdown: markdown)
        }
        let target = lectures[15].id
        var links = ConceptLinks()
        let duration = await Self.median(5) { links = ConceptLinks.build(for: target, lectures: lectures, texts: texts) }
        Self.report("ConceptLinks.build, предмет из 30 лекций", duration)
        _ = links
    }

    // MARK: Индекс учебников

    @Test(.enabled(if: PerformanceTests.enabled))
    func indexInsertScales() async throws {
        let store = try LiteratureStore.inMemory()
        let book = try await store.upsertBook(path: "/b.pdf", title: "Б", subject: "С", size: 1, mtime: 1, pages: 5000)
        let words = ["энтальпия", "энтропия", "реакция", "равновесие", "константа", "потенциал", "электрод", "раствор"]
        func page(_ n: Int) -> (number: Int, text: String, method: String) {
            (n, (0..<300).map { words[($0 * 7 + n) % words.count] }.joined(separator: " "), "ocr")
        }
        var first = Duration.zero, last = Duration.zero
        let clock = ContinuousClock()
        for batch in stride(from: 1, through: 5000, by: 20) {
            let pages = (batch..<batch + 20).map(page)
            let start = clock.now
            try await store.add(pages: pages, book: book)
            let spent = clock.now - start
            if batch <= 500 { first += spent }
            if batch > 4500 { last += spent }
        }
        Self.report("индекс: первые 500 страниц", first)
        Self.report("индекс: последние 500 страниц из 5000", last)
        #expect(try await store.totalPages() == 5000)
    }

    // MARK: Импорт

    @Test(.enabled(if: PerformanceTests.enabled))
    func importScannedPDF() throws {
        let dir = try TempDir()
        let pdf = dir.url.appendingPathComponent("скан.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try #require(CGContext(pdf as CFURL, mediaBox: &box, nil))
        for i in 0..<30 {
            context.beginPDFPage(nil)
            context.setFillColor(gray: 0.15, alpha: 1)
            for line in 0..<30 { context.fill(CGRect(x: 60, y: 60 + line * 24, width: 300 + (i * line) % 160, height: 6)) }
            context.endPDFPage()
        }
        context.closePDF()
        let paths = LecturePaths(folder: dir.url.appendingPathComponent("lecture"))
        let clock = ContinuousClock()
        let start = clock.now
        let result = SourceImporter(paths: paths).importFiles([pdf], into: .notes)
        Self.report("импорт PDF-скана, 30 страниц", clock.now - start)
        #expect(result.notes.count == 30)
    }
}

/// Ждёт загрузки `notes.html` в `WKWebView`.
@MainActor
final class PageLoader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?

    func load(_ view: WKWebView) async throws {
        let folder = try #require(NotesWebView.webFolder)
        view.navigationDelegate = self
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            view.loadFileURL(folder.appendingPathComponent("notes.html"), allowingReadAccessTo: folder)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }
}
