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

    /// Версия разбора страниц: при её росте страницы с текстовым слоем перечитываются (OCR не повторяется).
    static let version = 2

    struct Result: Equatable, Sendable {
        var text: String
        /// `layer` — текстовый слой, `ocr` — Vision.
        var method: String
    }

    static func extract(_ page: PDFPage) -> Result {
        let layer = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if layer.filter({ !$0.isWhitespace }).count >= minimumLayerCharacters {
            return Result(text: orderedLayer(of: page) ?? layer, method: "layer")
        }
        let recognized = ocr(page)
        // Скан с мусорным слоем: берём то, что длиннее.
        return recognized.count >= layer.count ? Result(text: recognized, method: "ocr") : Result(text: layer, method: "layer")
    }

    /// Текстовый слой в порядке чтения: у PDF из LaTeX дроби, индексы и степени идут в потоке не по порядку, и формулы
    /// рассыпаются. Строки берутся по геометрии (сверху вниз, на одной высоте слева направо). Для страниц в несколько
    /// колонок так склеивать нельзя: возвращается `nil`, и остаётся порядок самого PDF.
    static func orderedLayer(of page: PDFPage) -> String? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, let selection = page.selection(for: bounds) else { return nil }
        let rows: [(y: CGFloat, x: CGFloat, width: CGFloat, text: String)] = selection.selectionsByLine().compactMap { line in
            let text = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let box = line.bounds(for: page)
            return (box.midY, box.minX, box.width, text)
        }
        guard !rows.isEmpty else { return nil }
        let sorted = rows.sorted { abs($0.y - $1.y) > 4 ? $0.y > $1.y : $0.x < $1.x }
        var lines: [[(x: CGFloat, width: CGFloat, text: String)]] = []
        var lastY = CGFloat.infinity
        for row in sorted {
            if abs(row.y - lastY) > 4 { lines.append([]); lastY = row.y }
            lines[lines.count - 1].append((row.x, row.width, row.text))
        }
        // Две широкие строки на одной высоте — это колонки, а не формула.
        let wide = bounds.width * 0.3
        if lines.contains(where: { $0.filter { $0.width > wide }.count >= 2 }) { return nil }
        return lines.map { $0.map(\.text).joined(separator: " ") }.joined(separator: "\n")
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
