import AppKit
import WebKit

/// Невидимый `WKWebView` с тем же `notes.html`, что и окно: показывает конспект с титулом и ждёт сигнала `rendered`
/// из JS (KaTeX отрисовал формулы, шрифты загружены). Общий для PDF-экспорта и HTML-экспорта.
@MainActor
final class RenderedNotesPage: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let view: WKWebView
    private let configuration = WKWebViewConfiguration()
    private var script = ""
    private var rendered: CheckedContinuation<Void, Error>?

    /// `light` — всегда светлая тема (печать).
    init(light: Bool = false) {
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: 794, height: 1123), configuration: configuration)
        super.init()
        if light { view.appearance = NSAppearance(named: .aqua) }
        configuration.userContentController.add(self, name: "rendered")
        view.navigationDelegate = self
    }

    /// Загружает страницу и ждёт отрисовки не дольше 30 с. `expandSolutions` — решения задач раскрыты (печать).
    func show(markdown: String, heading: PrintHeading?, expandSolutions: Bool, timeoutError: any Error) async throws {
        guard let folder = NotesWebView.webFolder else { throw timeoutError }
        let json = (try? JSONEncoder().encode(markdown)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        let headingJSON = heading.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        script = (headingJSON.map { "window.inklingSetHeading(\($0));" } ?? "")
            + (expandSolutions ? "InklingRender.options.collapseSolutions = false; " : "")
            + "window.inklingShow(\(json))"
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            rendered = continuation
            view.loadFileURL(folder.appendingPathComponent("notes.html"), allowingReadAccessTo: folder)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(30))
                self?.finish(.failure(timeoutError))
            }
        }
    }

    /// Обработчик сообщений держит страницу: без этого вызова она не освободится.
    func close() {
        configuration.userContentController.removeScriptMessageHandler(forName: "rendered")
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation = rendered else { return }
        rendered = nil
        continuation.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(script)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        finish(.success(()))
    }
}
