import AppKit
import CoreGraphics

/// Колонтитулы готового PDF: слева «Предмет · Тема», справа «3 / 12». Печать WKWebView своих колонтитулов
/// не даёт, поэтому страницы перерисовываются в новый PDF с подписью внизу. Метаданные: название и программа.
/// Там же ставятся переходы из `navigation`: якоря заголовков, ссылки оглавления и закладки.
enum PDFFooter {
    static func stamp(_ url: URL, label: String, title: String, navigation: PDFNavigation.Plan? = nil) throws {
        guard let source = CGPDFDocument(url as CFURL), source.numberOfPages > 0 else {
            throw PDFExportError.printFailed
        }
        let temp = url.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).pdf")
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "Inkling"]
        guard let context = CGContext(temp as CFURL, mediaBox: nil, info as CFDictionary) else {
            throw PDFExportError.printFailed
        }
        let count = source.numberOfPages
        for index in 1...count {
            guard let page = source.page(at: index) else { continue }
            var box = page.getBoxRect(.mediaBox)
            context.beginPage(mediaBox: &box)
            context.drawPDFPage(page)
            draw(left: label, right: "\(index) / \(count)", in: box, context: context)
            for anchor in navigation?.anchors ?? [] where anchor.page == index - 1 {
                context.addDestination(anchor.name as CFString, at: anchor.point)
            }
            for link in navigation?.links ?? [] where link.page == index - 1 {
                context.setDestination(link.name as CFString, for: link.rect)
            }
            context.endPage()
        }
        if let navigation, !navigation.bookmarks.isEmpty { CGPDFContextSetOutline(context, navigation.outlineDictionary()) }
        context.closePDF()
        if navigation?.links.isEmpty == false { try PDFLinkInliner.inline(temp) }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }

    /// Строка на 24 pt выше нижнего края, по полям страницы (16 мм).
    private static func draw(left: String, right: String, in box: CGRect, context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8),
            .foregroundColor: NSColor(white: 0.45, alpha: 1),
        ]
        let margin: CGFloat = 45
        let baseline: CGFloat = 24
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let rightText = NSAttributedString(string: right, attributes: attributes)
        let rightWidth = rightText.size().width
        rightText.draw(at: CGPoint(x: box.maxX - margin - rightWidth, y: box.minY + baseline))
        let leftText = NSAttributedString(string: left, attributes: attributes)
        let available = box.width - margin * 2 - rightWidth - 16
        leftText.draw(with: CGRect(x: box.minX + margin, y: box.minY + baseline, width: available, height: 12),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        NSGraphicsContext.restoreGraphicsState()
    }
}
