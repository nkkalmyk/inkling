import AppKit
import Synchronization
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

extension PrintHeading {
    /// Титул лекции: предмет, тема и дата словами — одинаково для PDF, HTML и экспорта предмета.
    init(_ meta: LectureMeta) {
        self.init(subject: meta.subject, topic: meta.topic, date: meta.date.formatted)
    }
}

/// PDF A4 из отрендеренного конспекта (SPEC, раздел 8). Печать начинается только после сигнала
/// `rendered` из JS: KaTeX отрисовал формулы и загрузил шрифты. Печатается всегда светлая тема.
/// Первая страница начинается с титула (предмет, тема, дата), внизу каждой — колонтитул.
@MainActor
final class PDFExporter: NSObject {
    private var window: NSWindow?
    /// Заголовки и ссылки оглавления отрисованной страницы — для переходов в готовом PDF.
    private var outline: PDFNavigation.Outline?
    /// A4 в пунктах.
    static let a4 = NSSize(width: 595.28, height: 841.89)

    func export(markdown: String, title: String, heading: PrintHeading? = nil, to url: URL) async throws {
        let page = RenderedNotesPage(light: true)
        let view = page.view
        // Печати WKWebView нужно окно; оно невидимое и за пределами экрана.
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 794, height: 1123),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        window.orderBack(nil)
        self.window = window
        defer {
            page.close()
            window.orderOut(nil)
            self.window = nil
        }
        try await page.show(markdown: markdown, heading: heading, expandSolutions: true,
                            timeoutError: PDFExportError.renderTimeout)

        try Task.checkCancellation()
        if let json = try? await view.evaluateJavaScript(PDFNavigation.outlineScript) as? String {
            outline = try? JSONDecoder().decode(PDFNavigation.Outline.self, from: Data(json.utf8))
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
        // Печать идёт во временный файл рядом: прежний PDF заменяется только готовым новым, а при сбое остаётся.
        let printed = url.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: printed) }
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = printed
        let operation = view.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.jobTitle = title
        // WKWebView печатает асинхронно: синхронный run() зависает. Ждём завершения через делегат.
        let ok = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            printDone.set(continuation)
            operation.runModal(for: window, delegate: self,
                               didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
        guard ok, FileManager.default.fileExists(atPath: printed.path) else { throw PDFExportError.printFailed }
        // Отменили во время печати — прежний PDF не заменяется.
        try Task.checkCancellation()
        let label = heading.map { "\($0.subject) · \($0.topic)" } ?? title
        // Места ссылок ищутся в напечатанном файле, а ставятся при перерисовке с колонтитулами.
        let navigation = outline.flatMap { PDFNavigation.plan($0, for: printed) }
        try PDFFooter.stamp(printed, label: label, title: title, navigation: navigation)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: printed)
        } else {
            try FileManager.default.moveItem(at: printed, to: url)
        }
    }

    private nonisolated let printDone = OneShot()

    /// AppKit вызывает это в фоновом потоке, поэтому метод не привязан к главному актору.
    @objc private nonisolated func printOperationDidRun(_ operation: NSPrintOperation, success: Bool,
                                                        contextInfo: UnsafeMutableRawPointer?) {
        printDone.resume(success)
    }

    /// Продолжение, которое можно безопасно возобновить из любого потока, ровно один раз.
    private final class OneShot: Sendable {
        private let continuation = Mutex<CheckedContinuation<Bool, Never>?>(nil)

        func set(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation.withLock { $0 = continuation } }

        func resume(_ value: Bool) {
            let pending = continuation.withLock { stored -> CheckedContinuation<Bool, Never>? in
                defer { stored = nil }
                return stored
            }
            pending?.resume(returning: value)
        }
    }
}
