import Foundation
import Testing
@testable import Inkling

@MainActor
@Suite("Экспорт в HTML")
struct HTMLExportTests {
    private let rendered = HTMLExporter.Rendered(
        heading: "<header id=\"print-heading\"><p class=\"print-subject\">Алгебра</p><h1 class=\"print-topic\">Матрицы</h1></header>",
        content: "<h2 id=\"sec-1\">1. Виды</h2><nav class=\"toc\"><a href=\"#sec-1\">1. Виды</a></nav><p>Текст <b>&lt;тег&gt;</b></p>")

    @Test func fontsAreInlinedAndMissingFormatsDropped() {
        let css = #"@font-face{font-family:KaTeX_AMS;src:url(fonts/KaTeX_AMS-Regular.woff2) format("woff2"),url(fonts/KaTeX_AMS-Regular.woff) format("woff"),url(fonts/KaTeX_AMS-Regular.ttf) format("truetype")}"#
        let out = HTMLExporter.inlineFonts(css) { $0 == "KaTeX_AMS-Regular.woff2" ? Data([1, 2, 3]) : nil }
        #expect(out.contains("url(data:font/woff2;base64,AQID)"))
        #expect(!out.contains("fonts/"), "ни одной ссылки на файлы шрифтов")
    }

    @Test func singleLectureDocumentIsSelfContained() throws {
        let styles = try HTMLExporter.styles()
        let html = HTMLExporter.document(title: "Матрицы — Алгебра", sections: [.init(id: "lecture", title: "Матрицы", rendered: rendered)],
                                         toc: false, katexCSS: styles.katex, notesCSS: styles.notes)
        #expect(html.hasPrefix("<!doctype html>"))
        #expect(html.contains("default-src 'none'"), "CSP запрещает сеть")
        #expect(!html.contains("<script"))
        #expect(!html.contains("src=\"http") && !html.contains("url(http") && !html.contains("href=\"http"))
        #expect(!html.contains("url(fonts/"))
        #expect(html.contains("font/woff2;base64,"))
        #expect(html.contains("id=\"sec-1\"") && html.contains("href=\"#sec-1\""), "одна лекция — якоря как есть")
        #expect(!html.contains(NSHomeDirectory()), "нет домашних путей")
        #expect(html.contains("<title>Матрицы — Алгебра</title>"))
    }

    @Test func subjectSectionsGetPrefixedAnchorsAndToc() {
        let html = HTMLExporter.document(title: "Алгебра <все>", sections: [
            .init(id: "l1", title: "Матрицы", rendered: rendered), .init(id: "l2", title: "Миноры", rendered: rendered),
        ], toc: true, katexCSS: "", notesCSS: "#print-heading h1 { color: red; }\n@media print {\n  main, #print-heading { padding: 0; }\n}")
        #expect(html.contains("<title>Алгебра &lt;все&gt;</title>"))
        #expect(html.contains("<a href=\"#l2\">Миноры</a>"))
        #expect(html.contains("id=\"l1-sec-1\"") && html.contains("href=\"#l2-sec-1\""))
        #expect(!html.contains("id=\"sec-1\""), "якоря лекций не сталкиваются")
        #expect(html.contains(".print-heading h1 { color: red; }"), "стили титула для класса")
        #expect(!html.contains("main, .print-heading"), "печатные правила остаются в @media print")
    }

    @Test func htmlGoesNextToPdf() throws {
        let dir = try TempDir()
        let url = try ExportLocation.htmlURL(baseName: "Матрицы — Алгебра — 2026-10-13", subject: "Высшая алгебра", documents: dir.url)
        #expect(url.path.hasSuffix("Конспекты/высшая алгебра/Матрицы — Алгебра — 2026-10-13.html"))
    }
}
