import AppKit
import WebKit

enum HTMLExportError: LocalizedError {
    case renderTimeout
    case missingResources

    var errorDescription: String? {
        switch self {
        case .renderTimeout: "Конспект не успел отрисоваться для экспорта."
        case .missingResources: "В приложении не нашлись файлы оформления конспекта."
        }
    }
}

/// Конспект одним HTML-файлом (SPEC, раздел 13): уже отрисованная разметка, стили и шрифты KaTeX внутри, без скриптов.
/// Открывается офлайн в любом браузере — на телефоне, в Windows. Решения задач остаются под спойлером (`<details>`
/// работает без скриптов), тема следует системной, как в окне.
enum HTMLExporter {
    /// Отрисованный конспект: титул и содержимое `#content` из `notes.html`.
    struct Rendered: Sendable {
        var heading: String
        var content: String
    }

    /// Раздел файла: одна лекция. У предмета их несколько, каждая со своими якорями.
    struct Section: Sendable {
        var id: String
        var title: String
        var rendered: Rendered
    }

    /// Самодостаточный документ: CSP запрещает любые сетевые загрузки, стили и шрифты встроены.
    static func document(title: String, sections: [Section], toc: Bool, katexCSS: String, notesCSS: String) -> String {
        var body = ""
        if toc, sections.count > 1 {
            body += "<nav class=\"subject-toc\"><h1>\(escape(title))</h1><ol>"
            for section in sections { body += "<li><a href=\"#\(section.id)\">\(escape(section.title))</a></li>" }
            body += "</ol></nav>\n"
        }
        for section in sections {
            let prefix = sections.count > 1 ? "\(section.id)-" : ""
            body += "<article class=\"lecture\" id=\"\(section.id)\">\n"
            body += prefixed(section.rendered.heading, prefix: prefix) + "\n"
            body += "<main>" + prefixed(section.rendered.content, prefix: prefix) + "</main>\n</article>\n"
        }
        return """
        <!doctype html>
        <html lang="ru">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:">
        <meta name="color-scheme" content="light dark">
        <meta name="generator" content="Inkling">
        <title>\(escape(title))</title>
        <!-- KaTeX (katex.org), MIT License, Copyright (c) 2013-2020 Khan Academy and other contributors -->
        <style>\(katexCSS)</style>
        <style>\(notesCSS)\n\(headingCSS(notesCSS))\n\(extraCSS)</style>
        </head>
        <body>
        \(body)</body>
        </html>
        """
    }

    /// Стили файла поверх `notes.css`: титул лекции виден (в окне он только для печати), лекции предмета — с новой страницы.
    private static let extraCSS = """
    #print-heading, .print-heading { display: block; }
    article.lecture + article.lecture { margin-top: 48px; padding-top: 24px; border-top: 1px solid var(--rule); }
    nav.subject-toc { max-width: 720px; margin: 0 auto; padding: 32px 32px 0; font-family: var(--interface); }
    nav.subject-toc a { color: var(--text); }
    @media print { article.lecture + article.lecture { break-before: page; border-top: none; } }
    """

    /// В файле предмета титулов несколько, у них класс вместо id: правила `#print-heading` повторяются для `.print-heading`.
    /// Берутся только правила верхнего уровня (строки, которые с него начинаются), печатные остаются в `@media print`.
    static func headingCSS(_ notesCSS: String) -> String {
        notesCSS.split(separator: "\n").filter { $0.hasPrefix("#print-heading") }
            .map { $0.replacingOccurrences(of: "#print-heading", with: ".print-heading") }
            .joined(separator: "\n")
    }

    /// Якоря разделов (`sec-N`) уникальны только внутри лекции: в файле предмета они получают префикс лекции.
    static func prefixed(_ html: String, prefix: String) -> String {
        guard !prefix.isEmpty else { return html }
        return html.replacingOccurrences(of: "id=\"sec-", with: "id=\"\(prefix)sec-")
            .replacingOccurrences(of: "href=\"#sec-", with: "href=\"#\(prefix)sec-")
            .replacingOccurrences(of: "id=\"print-heading\"", with: "class=\"print-heading\"")
    }

    /// Шрифты KaTeX внутрь CSS: `.woff2` — данными, ссылки на `.woff` и `.ttf` (их в приложении нет) — убираются.
    static func inlineFonts(_ css: String, font: (String) -> Data?) -> String {
        var result = css.replacingOccurrences(of: #",url\(fonts/[^)]+\.(woff|ttf)\) format\("(woff|truetype)"\)"#,
                                              with: "", options: .regularExpression)
        let pattern = #/url\(fonts/([A-Za-z0-9_-]+\.woff2)\)/#
        for match in result.matches(of: pattern).reversed() {
            let name = String(match.output.1)
            guard let data = font(name) else { continue }
            result.replaceSubrange(match.range, with: "url(data:font/woff2;base64,\(data.base64EncodedString()))")
        }
        return result
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Стили приложения: KaTeX со встроенными шрифтами и `notes.css`.
    static func styles() throws -> (katex: String, notes: String) {
        guard let web = NotesWebView.webFolder,
              let katex = try? String(contentsOf: web.appendingPathComponent("vendor/katex/katex.min.css"), encoding: .utf8),
              let notes = try? String(contentsOf: web.appendingPathComponent("notes.css"), encoding: .utf8)
        else { throw HTMLExportError.missingResources }
        let fonts = web.appendingPathComponent("vendor/katex/fonts")
        return (inlineFonts(katex) { try? Data(contentsOf: fonts.appendingPathComponent($0)) }, notes)
    }

    /// Пишет файл атомарно.
    static func write(title: String, sections: [Section], toc: Bool = false, to url: URL) throws {
        let styles = try styles()
        let html = document(title: title, sections: sections, toc: toc, katexCSS: styles.katex, notesCSS: styles.notes)
        try AtomicFile.write(Data(html.utf8), to: url)
    }
}

/// Отрисовывает конспект в невидимом `WKWebView` тем же `notes.html`, что и окно, и отдаёт готовую разметку.
@MainActor
final class NotesRenderer: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private var markdown = ""
    private var heading: PrintHeading?
    private var rendered: CheckedContinuation<Void, Error>?

    func render(markdown: String, heading: PrintHeading) async throws -> HTMLExporter.Rendered {
        self.markdown = markdown
        self.heading = heading
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "rendered")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 794, height: 1123), configuration: configuration)
        view.navigationDelegate = self
        defer { configuration.userContentController.removeScriptMessageHandler(forName: "rendered") }
        guard let folder = NotesWebView.webFolder else { throw HTMLExportError.missingResources }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            rendered = continuation
            view.loadFileURL(folder.appendingPathComponent("notes.html"), allowingReadAccessTo: folder)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(30))
                self?.finish(.failure(HTMLExportError.renderTimeout))
            }
        }
        let script = "JSON.stringify({heading: document.getElementById('print-heading').outerHTML, "
            + "content: document.getElementById('content').innerHTML})"
        guard let json = try await view.evaluateJavaScript(script) as? String,
              let parts = try? JSONDecoder().decode([String: String].self, from: Data(json.utf8))
        else { throw HTMLExportError.renderTimeout }
        return HTMLExporter.Rendered(heading: parts["heading"] ?? "", content: parts["content"] ?? "")
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation = rendered else { return }
        rendered = nil
        continuation.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let json = (try? JSONEncoder().encode(markdown)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        let headingJSON = heading.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        let setHeading = headingJSON.map { "window.inklingSetHeading(\($0));" } ?? ""
        webView.evaluateJavaScript(setHeading + "window.inklingShow(\(json))")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        finish(.success(()))
    }
}
