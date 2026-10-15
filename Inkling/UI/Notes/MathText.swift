import SwiftUI
import WebKit

/// Текст поля учебных материалов: Markdown и формулы (SPEC, раздел 6.1). Без формул и блочной разметки —
/// обычный `Text` (быстро), иначе — маленький WKWebView с тем же рендером, что у конспекта.
struct MathText: View {
    let markdown: String
    var large = false

    var body: some View {
        if Self.needsWeb(markdown) {
            MathSnippetView(markdown: markdown, large: large)
        } else {
            Text(Self.attributed(markdown))
                .font(large ? .readingLarge : .reading)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func needsWeb(_ text: String) -> Bool {
        text.contains("$") || text.contains("\\") || text.contains("\n#") || text.hasPrefix("#")
            || text.contains("|") || text.contains("```") || text.contains("\n- ") || text.contains("\n1. ")
    }

    /// Однострочное превью для списков, где формулы не рисуются: простые формулы без `$`
    /// («$AB$» → «AB»), сложные (с командами `\…`) — многоточием.
    static func preview(_ text: String) -> AttributedString {
        let plain = text.replacing(/\$\$?([^$]+)\$\$?/) { match in
            let formula = String(match.output.1)
            if formula.contains("\\") { return "…" }
            return formula.filter { !"{}^_".contains($0) }
        }
        return attributed(plain.replacingOccurrences(of: "\n", with: " "))
    }

    static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

private struct MathSnippetView: View {
    let markdown: String
    let large: Bool
    @State private var height: CGFloat = 24

    var body: some View {
        SnippetWebView(markdown: markdown, large: large, height: $height)
            .frame(height: height)
            .frame(maxWidth: .infinity)
    }
}

private struct SnippetWebView: NSViewRepresentable {
    let markdown: String
    let large: Bool
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> PassthroughWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator.handler, name: "height")
        let view = PassthroughWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        if let folder = NotesWebView.webFolder {
            view.loadFileURL(folder.appendingPathComponent("snippet.html"), allowingReadAccessTo: folder)
        }
        return view
    }

    func updateNSView(_ view: PassthroughWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.show(in: view)
    }

    static func dismantleNSView(_ view: PassthroughWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "height")
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: SnippetWebView
        private var loaded = false
        private var shown: (String, Bool)?
        lazy var handler = HeightHandler { [weak self] height in self?.parent.height = max(height, 1) }

        init(_ parent: SnippetWebView) { self.parent = parent }

        func show(in view: WKWebView) {
            guard loaded, shown.map({ $0 != (parent.markdown, parent.large) }) ?? true else { return }
            shown = (parent.markdown, parent.large)
            let json = (try? JSONEncoder().encode(parent.markdown)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
            view.evaluateJavaScript("window.inklingShow(\(json), \(parent.large))")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            show(in: webView)
        }
    }

    final class HeightHandler: NSObject, WKScriptMessageHandler {
        let onHeight: @MainActor (CGFloat) -> Void

        init(onHeight: @escaping @MainActor (CGFloat) -> Void) { self.onHeight = onHeight }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let value = message.body as? NSNumber else { return }
            MainActor.assumeIsolated { onHeight(CGFloat(value.doubleValue)) }
        }
    }
}

/// Веб-вью внутри прокручиваемого списка: колесо прокрутки отдаёт родителю.
final class PassthroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}
