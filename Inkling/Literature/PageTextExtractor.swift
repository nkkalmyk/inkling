import CoreGraphics
import Foundation
import PDFKit
import Vision

/// Текст страницы PDF: из текстового слоя, а если его нет (скан), распознаётся Vision на устройстве.
enum PageTextExtractor {
    /// Меньше этого числа непробельных символов — слоя нет, страница считается картинкой.
    static let minimumLayerCharacters = 200
    /// Длинная сторона картинки для распознавания: хватает для печатного текста учебников.
    static let ocrLongSide: CGFloat = 2200
    /// Потолок размера страницы-плаката (как в аудите BUG-06).
    static let maxPageSide: CGFloat = 6000

    struct Result: Equatable, Sendable {
        var text: String
        /// `layer` — текстовый слой, `ocr` — Vision.
        var method: String
    }

    static func extract(_ page: PDFPage) -> Result {
        let layer = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if layer.filter({ !$0.isWhitespace }).count >= minimumLayerCharacters { return Result(text: layer, method: "layer") }
        let recognized = ocr(page)
        // Скан с мусорным слоем: берём то, что длиннее.
        return recognized.count >= layer.count ? Result(text: recognized, method: "ocr") : Result(text: layer, method: "layer")
    }

    static func ocr(_ page: PDFPage) -> String {
        autoreleasepool {
            let bounds = page.bounds(for: .mediaBox)
            let longest = max(bounds.width, bounds.height)
            guard longest > 0, longest < maxPageSide * 4, let image = render(page, bounds: bounds, longSide: ocrLongSide) else { return "" }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ru-RU", "en-US"]
            request.usesLanguageCorrection = true
            guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return "" }
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }
    }

    /// Страница в сером изображении заданной длинной стороны, на белом фоне.
    static func render(_ page: PDFPage, bounds: CGRect, longSide: CGFloat) -> CGImage? {
        let scale = longSide / max(bounds.width, bounds.height)
        let width = max(Int((bounds.width * scale).rounded()), 1), height = max(Int((bounds.height * scale).rounded()), 1)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }
}
