import AppKit
import SwiftUI

/// Редактор Markdown страницы. `[неразборчиво]` подсвечивается; щелчок по нему сообщает,
/// на какой доле высоты страницы (по номеру строки) находится место, чтобы приблизить фото.
struct PageTextEditor: NSViewRepresentable {
    @Binding var text: String
    var onIllegibleClick: (Double) -> Void = { _ in }

    static let illegible = "[неразборчиво]"
    private static let linkScheme = "inkling-illegible"

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = Self.font
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        textView.string = text
        context.coordinator.highlight(textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
        context.coordinator.highlight(textView)
    }

    private static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PageTextEditor

        init(_ parent: PageTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            highlight(textView)
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, url.scheme == PageTextEditor.linkScheme else { return false }
            let text = textView.string as NSString
            let before = text.substring(to: min(charIndex, text.length))
            let line = before.components(separatedBy: "\n").count - 1
            let total = max(text.components(separatedBy: "\n").count, 1)
            parent.onIllegibleClick((Double(line) + 0.5) / Double(total))
            return true
        }

        /// Подсветка `[неразборчиво]` атрибутами хранилища, без изменения самого текста.
        func highlight(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([.font: PageTextEditor.font, .foregroundColor: NSColor.textColor], range: full)
            let string = storage.string as NSString
            var search = full
            while true {
                let found = string.range(of: PageTextEditor.illegible, options: [], range: search)
                guard found.location != NSNotFound else { break }
                storage.addAttributes([
                    .backgroundColor: NSColor.systemYellow.withAlphaComponent(0.45),
                    .link: URL(string: "\(PageTextEditor.linkScheme)://\(found.location)")!,
                    .toolTip: "Щёлкните, чтобы приблизить это место на фото",
                ], range: found)
                let next = found.location + found.length
                search = NSRange(location: next, length: full.length - next)
            }
            // Догадки модели `[?слово]`: подчёркнуты точками, без перехода к фото.
            if let guesses = try? NSRegularExpression(pattern: #"\[\?[^\]\n]+\]"#) {
                for match in guesses.matches(in: storage.string, range: full) {
                    storage.addAttributes([
                        .underlineStyle: NSUnderlineStyle.patternDot.rawValue | NSUnderlineStyle.single.rawValue,
                        .underlineColor: NSColor.systemOrange,
                        .toolTip: "Догадка модели по смыслу: проверьте по фото",
                    ], range: match.range)
                }
            }
            storage.endEditing()
            textView.typingAttributes = [.font: PageTextEditor.font, .foregroundColor: NSColor.textColor]
        }
    }
}

/// Фото страницы с масштабированием жестом и прокруткой. `zoom` приближает место на заданной доле высоты.
struct ZoomableImageView: NSViewRepresentable {
    struct ZoomRequest: Equatable {
        var id = UUID()
        /// 0 — верх страницы, 1 — низ.
        var relativeY: Double
    }

    var image: NSImage?
    var zoom: ZoomRequest?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = FittingScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true
        scroll.maxMagnification = 8
        scroll.drawsBackground = false
        let imageView = NSImageView()
        imageView.imageScaling = .scaleAxesIndependently
        scroll.documentView = imageView
        let doubleClick = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.toggle(_:)))
        doubleClick.numberOfClicksRequired = 2
        scroll.addGestureRecognizer(doubleClick)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let scroll = scroll as? FittingScrollView, let imageView = scroll.documentView as? NSImageView else { return }
        if imageView.image !== image {
            imageView.image = image
            if let image {
                let size = image.representations.first.map { NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? image.size
                imageView.frame = NSRect(origin: .zero, size: size)
            }
            scroll.fitToView()
        }
        if let zoom, zoom != context.coordinator.lastZoom {
            context.coordinator.lastZoom = zoom
            let height = imageView.frame.height
            let point = NSPoint(x: imageView.frame.midX, y: height * (1 - zoom.relativeY))
            NSAnimationContext.runAnimationGroup { _ in
                scroll.animator().setMagnification(scroll.fitMagnification * 3, centeredAt: point)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var lastZoom: ZoomRequest?

        @objc func toggle(_ recognizer: NSClickGestureRecognizer) {
            guard let scroll = recognizer.view as? FittingScrollView, let document = scroll.documentView else { return }
            if scroll.magnification > scroll.fitMagnification * 1.05 {
                scroll.animator().magnification = scroll.fitMagnification
            } else {
                let point = document.convert(recognizer.location(in: scroll), from: scroll)
                scroll.animator().setMagnification(scroll.fitMagnification * 2.5, centeredAt: point)
            }
        }
    }

    /// Прокрутка, которая при смене размера держит картинку целиком, пока её не приблизили.
    final class FittingScrollView: NSScrollView {
        var fitMagnification: CGFloat = 1

        func fitToView() {
            guard let document = documentView, document.frame.width > 0, document.frame.height > 0 else { return }
            let bounds = contentView.frame.size
            fitMagnification = max(min(bounds.width / document.frame.width, bounds.height / document.frame.height), 0.01)
            minMagnification = fitMagnification
            magnification = fitMagnification
        }

        override func layout() {
            let wasFitted = abs(magnification - fitMagnification) < 0.001
            super.layout()
            if wasFitted { fitToView() }
        }
    }
}
