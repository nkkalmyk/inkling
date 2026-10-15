import AppKit
import ImageIO
import PDFKit

/// Что показать для страницы: готовый JPEG или страницу PDF.
enum PageImageSource: Hashable, Sendable {
    case file(URL)
    case pdfPage(URL, index: Int)
}

/// Загрузка уменьшенных картинок страниц в фоне с кэшем. PDF рисуются последовательно в одном акторе:
/// `PDFDocument` не рассчитан на одновременную работу из нескольких потоков.
actor PageImageLoader {
    static let shared = PageImageLoader()

    private let cache = NSCache<NSString, NSImage>()
    private var documents: [URL: PDFDocument] = [:]

    func image(_ source: PageImageSource, maxPixel: Int, revision: Int) -> NSImage? {
        let key = "\(source)#\(maxPixel)#\(revision)#\(modificationDate(source))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image: NSImage?
        switch source {
        case .file(let url): image = Self.downsampled(url, maxPixel: maxPixel)
        case .pdfPage(let url, let index): image = pdfThumbnail(url, index: index, maxPixel: maxPixel)
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    private func modificationDate(_ source: PageImageSource) -> TimeInterval {
        let url: URL = switch source {
        case .file(let url), .pdfPage(let url, _): url
        }
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return date?.timeIntervalSince1970 ?? 0
    }

    private static func downsampled(_ url: URL, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private func pdfThumbnail(_ url: URL, index: Int, maxPixel: Int) -> NSImage? {
        let document = documents[url] ?? PDFDocument(url: url)
        documents[url] = document
        guard let page = document?.page(at: index) else { return nil }
        let bounds = page.bounds(for: .cropBox)
        let scale = CGFloat(maxPixel) / max(bounds.width, bounds.height, 1)
        return page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .cropBox)
    }
}
