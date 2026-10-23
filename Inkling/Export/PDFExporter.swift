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

/// Титул первой страницы PDF.
struct PrintHeading: Encodable {
    var subject: String
    var topic: String
    var date: String
}

/// PDF A4 из отрендеренного конспекта (SPEC, раздел 8). Печать начинается только после сигнала
/// `rendered` из JS: KaTeX отрисовал формулы и загрузил шрифты. Печатается всегда светлая тема.
/// Первая страница начинается с титула (предмет, тема, дата), внизу каждой — колонтитул.
@MainActor
final class PDFExporter: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private var webView: WKWebView?
    private var window: NSWindow?
    private var markdown = ""
    private var heading: PrintHeading?
    private var rendered: CheckedContinuation<Void, Error>?

    /// A4 в пунктах.
    static let a4 = NSSize(width: 595.28, height: 841.89)

    func export(markdown: String, title: String, heading: PrintHeading? = nil, to url: URL) async throws {
        self.markdown = markdown
        self.heading = heading
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
        try? FileManager.default.removeItem(at: url)
        // WKWebView печатает асинхронно: синхронный run() зависает. Ждём завершения через делегат.
        let ok = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            printed.set(continuation)
            operation.runModal(for: window, delegate: self,
                               didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
        guard ok, FileManager.default.fileExists(atPath: url.path) else { throw PDFExportError.printFailed }
        let label = heading.map { "\($0.subject) · \($0.topic)" } ?? title
        try PDFFooter.stamp(url, label: label, title: title)
    }

    private nonisolated let printed = OneShot()

    /// AppKit вызывает это в фоновом потоке, поэтому метод не привязан к главному актору.
    @objc private nonisolated func printOperationDidRun(_ operation: NSPrintOperation, success: Bool,
                                                        contextInfo: UnsafeMutableRawPointer?) {
        printed.resume(success)
    }

    /// Продолжение, которое можно безопасно возобновить из любого потока, ровно один раз.
    private final class OneShot: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        func set(_ continuation: CheckedContinuation<Bool, Never>) { lock.withLock { self.continuation = continuation } }

        func resume(_ value: Bool) {
            let pending = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(returning: value)
        }
    }

    private func finishRender(_ result: Result<Void, Error>) {
        guard let continuation = rendered else { return }
        rendered = nil
        continuation.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let json = (try? JSONEncoder().encode(markdown)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        let headingJSON = heading.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        let setHeading = headingJSON.map { "window.inklingSetHeading(\($0));" } ?? ""
        webView.evaluateJavaScript(setHeading + "InklingRender.options.collapseSolutions = false; window.inklingShow(\(json))")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        finishRender(.success(()))
    }
}
