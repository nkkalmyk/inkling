import AppKit
import SwiftUI

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
