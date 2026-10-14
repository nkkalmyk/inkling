import AppKit
import WebKit

enum PDFExportError: LocalizedError {
    case renderTimeout
    case printFailed

    var errorDescription: String? {
        switch self {
        case .renderTimeout: "Конспект не успел отрисоваться для печати."
        case .printFailed: "Не удалось сохранить PDF."
        }
    }
}

/// PDF A4 из отрендеренного конспекта (SPEC, раздел 8). Печать начинается только после сигнала
/// `rendered` из JS: KaTeX отрисовал формулы и загрузил шрифты. Печатается всегда светлая тема.
@MainActor
final class PDFExporter: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private var webView: WKWebView?
    private var window: NSWindow?
    private var markdown = ""
    private var rendered: CheckedContinuation<Void, Error>?

    /// A4 в пунктах.
    static let a4 = NSSize(width: 595.28, height: 841.89)

    func export(markdown: String, title: String, to url: URL) async throws {
        self.markdown = markdown
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "rendered")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 794, height: 1123), configuration: configuration)
        view.appearance = NSAppearance(named: .aqua)
        view.navigationDelegate = self
        // Печати WKWebView нужно окно; оно невидимое и за пределами экрана.
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 794, height: 1123),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        window.orderBack(nil)
        self.webView = view
        self.window = window
        defer {
            configuration.userContentController.removeScriptMessageHandler(forName: "rendered")
            window.orderOut(nil)
            self.window = nil
            self.webView = nil
        }

        guard let folder = NotesWebView.webFolder else { throw PDFExportError.printFailed }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            rendered = continuation
            view.loadFileURL(folder.appendingPathComponent("notes.html"), allowingReadAccessTo: folder)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(30))
                self?.finishRender(.failure(PDFExportError.renderTimeout))
            }
        }

        let info = NSPrintInfo()
        info.paperSize = Self.a4
        info.orientation = .portrait
        // Поля 18 мм сверху и снизу, 16 мм по бокам.
        info.topMargin = 51
        info.bottomMargin = 51
        info.leftMargin = 45
        info.rightMargin = 45
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let operation = view.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.jobTitle = title
        operation.view?.frame = view.bounds
        try? FileManager.default.removeItem(at: url)
        _ = operation.run()
        guard FileManager.default.fileExists(atPath: url.path) else { throw PDFExportError.printFailed }
    }

    private func finishRender(_ result: Result<Void, Error>) {
        guard let continuation = rendered else { return }
        rendered = nil
        continuation.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let json = (try? JSONEncoder().encode(markdown)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        webView.evaluateJavaScript("window.inklingShow(\(json))")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        finishRender(.success(()))
    }
}
