import SwiftUI
import WebKit

/// Отрисованный конспект: WKWebView + KaTeX + mhchem, офлайн из бандла (SPEC, раздел 7).
/// Тема следует системной: `prefers-color-scheme` в CSS. После отрисовки и загрузки шрифтов
/// страница присылает сигнал `rendered` (для печати в PDF на этапе экспорта).
struct NotesWebView: NSViewRepresentable {
    var markdown: String
    /// Ссылки на соседние лекции под конспектом; в текст конспекта они не попадают.
    var neighbors = LectureNeighbors()
    /// Ссылки по понятиям на другие лекции и «Связанные лекции»; тоже не часть текста конспекта.
    var concepts = ConceptLinks()
    /// Раздел, к которому прокрутить; после прокрутки вызывается `onScrolled`, и запрос снимается.
    var anchor: String?
    var onScrolled: () -> Void = {}
    var openLecture: (_ id: UUID, _ anchor: String?) -> Void = { _, _ in }
    @Environment(\.readingScale) private var readingScale
    var onRendered: (_ katexErrors: Int) -> Void = { _ in }

    nonisolated static var webFolder: URL? { Bundle.main.url(forResource: "Web", withExtension: nil) }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(WeakMessageHandler(context.coordinator), name: "rendered")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        if let folder = Self.webFolder {
            view.loadFileURL(folder.appendingPathComponent("notes.html"), allowingReadAccessTo: folder)
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        // «Крупнее/Мельче» масштабирует конспект целиком, как ⌘+ в Safari: текст, формулы и ширина колонки.
        if view.pageZoom != readingScale { view.pageZoom = readingScale }
        context.coordinator.show(markdown, in: view)
        context.coordinator.showNeighbors(neighbors, in: view)
        context.coordinator.showConcepts(concepts, in: view)
        context.coordinator.scroll(to: anchor, in: view)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "rendered")
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: NotesWebView
        private var loaded = false
        private var shown: String?
        private var shownNeighbors: LectureNeighbors?
        private var shownConcepts: ConceptLinks?

        init(_ parent: NotesWebView) { self.parent = parent }

        func show(_ markdown: String, in view: WKWebView) {
            guard loaded, markdown != shown else { return }
            shown = markdown
            let json = (try? JSONEncoder().encode(markdown)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
            view.evaluateJavaScript("window.inklingShow(\(json))")
        }

        func showNeighbors(_ neighbors: LectureNeighbors, in view: WKWebView) {
            guard loaded, neighbors != shownNeighbors else { return }
            shownNeighbors = neighbors
            struct Payload: Encodable { var previous, next: LectureNeighbors.Link? }
            let json = (try? JSONEncoder().encode(Payload(previous: neighbors.previous, next: neighbors.next)))
                .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            view.evaluateJavaScript("window.inklingSetNeighbors(\(json))")
        }

        func showConcepts(_ concepts: ConceptLinks, in view: WKWebView) {
            guard loaded, concepts != shownConcepts else { return }
            shownConcepts = concepts
            let json = (try? JSONEncoder().encode(concepts)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            view.evaluateJavaScript("window.inklingSetConcepts(\(json))")
        }

        /// Когда конспект уже показан; запрос одноразовый — дальше пользователь листает сам.
        func scroll(to anchor: String?, in view: WKWebView) {
            guard loaded, let anchor, shown?.isEmpty == false else { return }
            // Снимаем запрос после обновления вида: менять состояние внутри `updateNSView` нельзя.
            let done = parent.onScrolled
            Task { done() }
            let json = (try? JSONEncoder().encode(anchor)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
            view.evaluateJavaScript("window.inklingScrollTo(\(json))")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            show(parent.markdown, in: webView)
            showNeighbors(parent.neighbors, in: webView)
            showConcepts(parent.concepts, in: webView)
            scroll(to: parent.anchor, in: webView)
        }

        /// Ссылки из конспекта открываются в браузере, а не внутри приложения; `inkling-lecture://<id>` — другая лекция.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url, url.scheme != "file" {
                if let id = Self.lectureID(url) {
                    parent.openLecture(id, Self.anchor(url))
                } else if Self.opensExternally(url) {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        /// Только веб-ссылки и почта: схемы вроде `smb:` или `shortcuts:` ответ модели открывать не должен.
        nonisolated static func opensExternally(_ url: URL) -> Bool {
            ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
        }

        nonisolated static let lectureScheme = "inkling-lecture"

        nonisolated static func lectureID(_ url: URL) -> UUID? {
            guard url.scheme?.lowercased() == lectureScheme, let host = url.host() else { return nil }
            return UUID(uuidString: host)
        }

        /// Раздел из ссылки на понятие: только якоря вида `sec-N`, как их ставит `render.js`.
        nonisolated static func anchor(_ url: URL) -> String? {
            guard let fragment = url.fragment(), fragment.wholeMatch(of: /sec-\d+/) != nil else { return nil }
            return fragment
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            let errors = (message.body as? [String: Any])?["errors"] as? Int ?? 0
            parent.onRendered(errors)
        }
    }

    /// WKUserContentController держит обработчик сильной ссылкой; прослойка разрывает цикл.
    private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
        weak var target: (any WKScriptMessageHandler)?

        init(_ target: any WKScriptMessageHandler) { self.target = target }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            target?.userContentController(controller, didReceive: message)
        }
    }
}
