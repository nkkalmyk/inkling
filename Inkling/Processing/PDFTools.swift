import CoreImage
import Foundation
import PDFKit

enum PDFToolsError: LocalizedError {
    case unreadable(String)
    case pageMissing(Int)
    case tooManyPages(String, Int)

    var errorDescription: String? {
        switch self {
        case .tooManyPages(let name, let count): "В PDF «\(name)» \(count) страниц, больше допустимых \(PDFTools.maxPages)."
        case .unreadable(let name): "Не удалось открыть PDF «\(name)». Возможно, файл повреждён или защищён паролем."
        case .pageMissing(let index): "В PDF нет страницы \(index + 1)."
        }
    }
}

/// Работа с PDF через PDFKit (SPEC, разделы 3.1–3.3).
enum PDFTools {
    /// Средняя длина текстового слоя на первых страницах, с которой PDF считается слайдами.
    static let slidesTextThreshold = 50

    /// Потолок числа страниц: больше — почти наверняка не конспект, а покадровый рендер съест время и память.
    static let maxPages = 2000

    static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url), !document.isLocked else {
            throw PDFToolsError.unreadable(url.lastPathComponent)
        }
        guard document.pageCount <= maxPages else {
            throw PDFToolsError.tooManyPages(url.lastPathComponent, document.pageCount)
        }
        return document
    }

    static func pageCount(_ url: URL) throws -> Int { try open(url).pageCount }

    /// Текстовый слой каждой страницы.
    static func pageTexts(_ url: URL) throws -> [String] {
        let document = try open(url)
        return (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
    }

    /// Куда, скорее всего, относится PDF: с текстовым слоем — слайды, без него — скан тетради.
    static func guessSection(_ url: URL) throws -> SourceSection {
        let document = try open(url)
        let sample = min(document.pageCount, 5)
        guard sample > 0 else { return .notes }
        let chars = (0..<sample).reduce(0) { total, i in
            total + (document.page(at: i)?.string ?? "").filter { !$0.isWhitespace }.count
        }
        return chars / sample >= slidesTextThreshold ? .slides : .notes
    }

    /// Рисует страницу на белом фоне. `dpi` 200 хватает для рукописи и формул на слайдах.
    static func renderPage(_ url: URL, index: Int, dpi: CGFloat = 200) throws -> CIImage {
        let document = try open(url)
        guard let page = document.page(at: index) else { throw PDFToolsError.pageMissing(index) }
        return try render(page, dpi: dpi)
    }

    static func render(_ page: PDFPage, dpi: CGFloat) throws -> CIImage {
        let bounds = page.bounds(for: .cropBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        let size = rotation == 90 || rotation == 270 ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        var scale = dpi / 72
        // Ограничиваем огромные страницы (плакаты), чтобы не съесть память.
        let maxSide: CGFloat = 6000
        scale = min(scale, maxSide / max(size.width, size.height, 1))
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw PDFToolsError.pageMissing(0)
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: ctx)
        guard let image = ctx.makeImage() else { throw PDFToolsError.pageMissing(0) }
        return CIImage(cgImage: image)
    }
}

/// Эвристика «текстовый слой или картинка» для слайдов (SPEC, раздел 3.3).
/// Слайд отправляется в модель картинкой, если текста почти нет или текстовый слой похож на мусор.
enum SlideTextHeuristic {
    struct Verdict: Equatable, Sendable {
        var needsImage: Bool
        var reason: String?
    }

    /// Меньше стольких значимых символов — текста «почти нет».
    static let minChars = 40
    /// Доля мусорных символов (U+FFFD, частная область Юникода, управляющие).
    static let maxGarbageRatio = 0.02
    /// Доля математических символов — формулы в текстовом слое почти всегда разваливаются.
    static let maxMathRatio = 0.06
    /// Доля «обломков»: строк из одного-двух символов.
    static let maxFragmentLineRatio = 0.4

    static func analyze(_ text: String) -> Verdict {
        let significant = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        let count = significant.count
        if count < minChars {
            return Verdict(needsImage: true, reason: count == 0 ? "нет текстового слоя" : "текста почти нет")
        }

        let garbage = significant.filter(isGarbage).count
        if Double(garbage) / Double(count) > maxGarbageRatio {
            return Verdict(needsImage: true, reason: "нераспознанные символы в текстовом слое")
        }

        let math = significant.filter(isMath).count
        if Double(math) / Double(count) > maxMathRatio {
            return Verdict(needsImage: true, reason: "формулы")
        }

        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if lines.count >= 6 {
            let fragments = lines.filter { $0.count <= 2 }.count
            if Double(fragments) / Double(lines.count) > maxFragmentLineRatio {
                return Verdict(needsImage: true, reason: "разорванный текст")
            }
        }
        return Verdict(needsImage: false, reason: nil)
    }

    private static func isGarbage(_ s: Unicode.Scalar) -> Bool {
        s == "\u{FFFD}"
            || (0xE000...0xF8FF).contains(s.value)
            || (0xF0000...0x10FFFF).contains(s.value)
            || (s.properties.generalCategory == .control && s != "\t")
    }

    private static let mathScalars = Set("=+±×÷∑∏∫∮√∞≈≠≤≥∂∇∈∉⊂⊆∪∩→←↔⇒⇔^_′″·∘‖∠°".unicodeScalars)

    private static func isMath(_ s: Unicode.Scalar) -> Bool {
        if mathScalars.contains(s) { return true }
        // Греческие буквы и математические алфавитно-цифровые символы.
        return (0x0391...0x03C9).contains(s.value) || (0x1D400...0x1D7FF).contains(s.value)
            || (0x2200...0x22FF).contains(s.value)
    }
}
