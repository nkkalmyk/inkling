import AppKit
import ImageIO
import PDFKit
import SwiftUI

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

/// Картинка страницы, которая подгружается асинхронно.
struct PageImageView: View {
    let source: PageImageSource?
    var maxPixel = 480
    var revision = 0

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(.quaternary)
                ProgressView().controlSize(.small)
            }
        }
        .task(id: TaskKey(source: source, maxPixel: maxPixel, revision: revision)) {
            guard let source else { return }
            image = await PageImageLoader.shared.image(source, maxPixel: maxPixel, revision: revision)
        }
    }

    private struct TaskKey: Hashable {
        var source: PageImageSource?
        var maxPixel: Int
        var revision: Int
    }
}

extension LecturePaths {
    func imageSource(for page: NotePage) -> PageImageSource {
        .file(notePhoto(page.id))
    }

    /// Для слайда-картинки — подготовленный JPEG, иначе сама страница PDF.
    func imageSource(for page: SlidePage) -> PageImageSource {
        switch page.source {
        case .image:
            return .file(original(page.source, in: .slides))
        case .pdfPage(_, let index):
            let jpeg = slideImage(page.id)
            if page.usesImage, FileManager.default.fileExists(atPath: jpeg.path) { return .file(jpeg) }
            return .pdfPage(original(page.source, in: .slides), index: index)
        }
    }
}
