import CoreImage
import CoreServices
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

enum ImageProcessingError: LocalizedError {
    case unreadable(String)
    case encodingFailed
    case tooLarge(String)

    var errorDescription: String? {
        switch self {
        case .tooLarge(let name): "Изображение «\(name)» слишком большое (больше 300 мегапикселей)."
        case .unreadable(let name): "Не удалось прочитать изображение «\(name)»."
        case .encodingFailed: "Не удалось сохранить изображение в JPEG."
        }
    }
}

/// Предобработка фото рукописи (SPEC, раздел 3.2): поворот по EXIF, обрезка и выпрямление документа,
/// поворот пользователем, уменьшение до ~2000 px, JPEG ~0.85. Только системные фреймворки.
enum ImageProcessor {
    /// Потолок размера исходной картинки (фото с телефона — 12–50 мегапикселей).
    static let maxPixels = 300_000_000

    static let maxDimension: CGFloat = 2000
    static let jpegQuality: CGFloat = 0.85

    /// Доли кадра, при которых найденный документ не обрезается: слишком мелкий — скорее ошибка,
    /// почти весь кадр — обрезать нечего.
    static let minDocumentArea = 0.15
    static let maxDocumentArea = 0.97

    private static let context = CIContext(options: [.cacheIntermediates: false])

    // MARK: Загрузка

    /// Картинка с уже применённой EXIF-ориентацией, начало координат в (0, 0). HEIC читается так же.
    static func loadOriented(_ url: URL) throws -> CIImage {
        // Размер читается из заголовка, до декодирования: «бомба» в картинке не должна съесть память.
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
           w * h > maxPixels {
            throw ImageProcessingError.tooLarge(url.lastPathComponent)
        }
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw ImageProcessingError.unreadable(url.lastPathComponent)
        }
        return normalized(image)
    }

    /// Когда снят кадр, для порядка страниц: EXIF → дата в имени файла (скриншоты, `IMG_…`) →
    /// дата создания из Spotlight → дата создания файла.
    static func shotDate(of url: URL) -> Date? {
        if let exif = captureDate(of: url) { return exif }
        if let named = dateFromFileName(url.deletingPathExtension().lastPathComponent) { return named }
        if let item = MDItemCreateWithURL(nil, url as CFURL),
           let date = MDItemCopyAttribute(item, kMDItemContentCreationDate) as? Date { return date }
        return (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    /// Дата и время из имени файла: «Снимок экрана 2026-10-14 в 12.30.45», «Screenshot 2026-10-14 at 12.30.45 PM»,
    /// «IMG_20261014_123045», «PXL_20261014_123045123», «2026-10-14 12-30-45». Время — местное.
    static func dateFromFileName(_ name: String, timeZone: TimeZone = .current) -> Date? {
        let patterns = [
            #"(\d{4})-(\d{2})-(\d{2})\D{1,6}?(\d{1,2})[.:\-](\d{2})[.:\-](\d{2})(?:\s*([AaPp][Mm]))?"#,
            #"(\d{4})(\d{2})(\d{2})[_\-](\d{2})(\d{2})(\d{2})"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) else { continue }
            func group(_ i: Int) -> String? {
                guard i < match.numberOfRanges, let range = Range(match.range(at: i), in: name) else { return nil }
                return String(name[range])
            }
            guard let y = group(1).flatMap(Int.init), let mo = group(2).flatMap(Int.init), let d = group(3).flatMap(Int.init),
                  var h = group(4).flatMap(Int.init), let mi = group(5).flatMap(Int.init), let se = group(6).flatMap(Int.init)
            else { continue }
            if let ampm = group(7)?.lowercased() {
                if ampm == "pm", h < 12 { h += 12 }
                if ampm == "am", h == 12 { h = 0 }
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let parts = DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: se)
            guard (2000...2100).contains(y), let date = calendar.date(from: parts),
                  calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date) == parts
            else { continue }
            return date
        }
        return nil
    }

    /// Дата съёмки из EXIF (`DateTimeOriginal` со смещением `OffsetTimeOriginal`, если оно есть).
    static func captureDate(of url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        guard let raw = (exif?[kCGImagePropertyExifDateTimeOriginal] ?? exif?[kCGImagePropertyExifDateTimeDigitized]
                         ?? tiff?[kCGImagePropertyTIFFDateTime]) as? String else { return nil }
        let offset = (exif?[kCGImagePropertyExifOffsetTimeOriginal] ?? exif?[kCGImagePropertyExifOffsetTime]) as? String
        return parseExifDate(raw, offset: offset)
    }

    /// `2026:10:14 09:30:00` + `+03:00`. Без смещения — местное время.
    static func parseExifDate(_ raw: String, offset: String?, defaultTimeZone: TimeZone = .current) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = offset.flatMap(timeZone(fromOffset:)) ?? defaultTimeZone
        return formatter.date(from: raw.trimmingCharacters(in: .whitespaces).prefix(19).description)
    }

    private static func timeZone(fromOffset raw: String) -> TimeZone? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.count == 6, let sign = s.first, sign == "+" || sign == "-",
              let h = Int(s.dropFirst().prefix(2)), let m = Int(s.suffix(2)) else { return nil }
        return TimeZone(secondsFromGMT: (sign == "-" ? -1 : 1) * (h * 3600 + m * 60))
    }

    // MARK: Документ

    /// Ищет лист бумаги в кадре. Возвращает `nil`, если документ не найден или обрезать нечего.
    static func detectDocument(in image: CIImage) -> Quad? {
        let small = resized(image, maxDimension: 1024)
        let handler = VNImageRequestHandler(ciImage: small, options: [:])
        let segmentation = VNDetectDocumentSegmentationRequest()
        let rectangles = VNDetectRectanglesRequest()
        rectangles.maximumObservations = 1
        rectangles.minimumConfidence = 0.6
        rectangles.minimumSize = 0.3
        rectangles.quadratureTolerance = 30

        for request in [segmentation as VNImageBasedRequest, rectangles] {
            guard (try? handler.perform([request])) != nil,
                  let observation = (request.results as? [VNRectangleObservation])?.first,
                  observation.confidence >= 0.5 else { continue }
            let quad = Quad(topLeft: observation.topLeft, topRight: observation.topRight,
                            bottomRight: observation.bottomRight, bottomLeft: observation.bottomLeft)
            if quad.area >= minDocumentArea && quad.area <= maxDocumentArea { return quad }
        }
        return nil
    }

    /// Выпрямляет перспективу по четырёхугольнику (нормированные координаты).
    static func perspectiveCorrected(_ image: CIImage, quad: Quad) -> CIImage {
        let e = image.extent
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: e.minX + p.x * e.width, y: e.minY + p.y * e.height) }
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = image
        filter.topLeft = point(quad.topLeft)
        filter.topRight = point(quad.topRight)
        filter.bottomRight = point(quad.bottomRight)
        filter.bottomLeft = point(quad.bottomLeft)
        return filter.outputImage.map(normalized) ?? image
    }

    // MARK: Геометрия

    /// Поворот на четверти оборота по часовой стрелке.
    static func rotated(_ image: CIImage, quarterTurns: Int) -> CIImage {
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: normalized(image.oriented(.right))
        case 2: normalized(image.oriented(.down))
        case 3: normalized(image.oriented(.left))
        default: image
        }
    }

    /// Уменьшает так, чтобы длинная сторона была не больше `maxDimension`. Не увеличивает.
    static func resized(_ image: CIImage, maxDimension: CGFloat) -> CIImage {
        let longest = max(image.extent.width, image.extent.height)
        guard longest > maxDimension, longest > 0 else { return image }
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = image
        filter.scale = Float(maxDimension / longest)
        filter.aspectRatio = 1
        guard let output = filter.outputImage else { return image }
        // Lanczos даёт дробный край; обрезаем до целых пикселей.
        return normalized(output).cropped(to: CGRect(x: 0, y: 0, width: floor(output.extent.width),
                                                     height: floor(output.extent.height)))
    }

    /// Для локальной модели: картинку меньше `below` по длинной стороне увеличивает (не больше чем в 2 раза
    /// и не больше `target`). На мелких скриншотах плотного почерка это заметно снижает ошибки распознавания.
    static func upscaledForModel(_ image: CIImage, below: CGFloat = 1600, target: CGFloat = 2000) -> CIImage {
        let longest = max(image.extent.width, image.extent.height)
        guard longest > 0, longest < below else { return image }
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = image
        filter.scale = Float(min(2, target / longest))
        filter.aspectRatio = 1
        guard let output = filter.outputImage else { return image }
        return normalized(output).cropped(to: CGRect(x: 0, y: 0, width: floor(output.extent.width),
                                                     height: floor(output.extent.height)))
    }

    private static func normalized(_ image: CIImage) -> CIImage {
        let origin = image.extent.origin
        guard origin != .zero else { return image }
        return image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
    }

    // MARK: Конвейер

    struct Result: Sendable {
        var jpeg: Data
        /// Найденный документ (только для `.auto` без сохранённого четырёхугольника).
        var detectedQuad: Quad?
        var pixelSize: CGSize
    }

    /// Обрезка, выпрямление и поворот без сжатия до JPEG; длинная сторона не больше `maxDimension`.
    static func prepared(_ original: CIImage, crop: CropMode, rotation: Int, maxDimension: CGFloat,
                         detect: Bool = true) -> (image: CIImage, detected: Quad?) {
        var image = original
        var detected: Quad?
        switch crop {
        case .original:
            break
        case .auto(let saved):
            let quad = saved ?? (detect ? detectDocument(in: image) : nil)
            detected = saved == nil ? quad : nil
            if let quad { image = perspectiveCorrected(image, quad: quad) }
        case .manual(let quad):
            image = perspectiveCorrected(image, quad: quad)
        }
        return (resized(rotated(image, quarterTurns: rotation), maxDimension: maxDimension), detected)
    }

    /// Полный конвейер для фото рукописи. Для `.auto(nil)` документ ищется заново.
    static func process(_ original: CIImage, crop: CropMode, rotation: Int, detect: Bool = true) throws -> Result {
        let (image, detected) = prepared(original, crop: crop, rotation: rotation, maxDimension: maxDimension, detect: detect)
        return Result(jpeg: try jpegData(image), detectedQuad: detected, pixelSize: image.extent.size)
    }

    // MARK: Режим «Подробно»

    /// Размер длинной стороны при разбиении на фрагменты: крупнее обычных 2000 px, чтобы мелкие детали не терялись.
    static let detailedMaxDimension: CGFloat = 4500
    static let detailedBandCount = 3
    /// Доля высоты фрагмента, которая перекрывается с соседним: строка на стыке целиком попадает в один из них.
    static let detailedOverlap: Double = 0.2

    /// Режет картинку на горизонтальные фрагменты сверху вниз с перекрытием.
    static func bands(of image: CIImage, count: Int, overlap: Double) -> [CIImage] {
        let n = max(count, 1)
        let extent = image.extent
        guard n > 1, extent.height > 0 else { return [image] }
        let o = min(max(overlap, 0), 0.5)
        let height = extent.height / (Double(n) - Double(n - 1) * o)
        let step = height * (1 - o)
        return (0..<n).map { index in
            // У CIImage начало координат внизу, поэтому первый фрагмент — самый верхний.
            let top = extent.maxY - Double(index) * step
            let y = max(top - height, extent.minY)
            let rect = CGRect(x: extent.minX, y: y, width: extent.width, height: min(height, top - y))
            return normalized(image.cropped(to: rect.integral))
        }
    }

    /// JPEG-фрагменты страницы для распознавания «Подробно», сверху вниз.
    static func detailedBands(_ original: CIImage, crop: CropMode, rotation: Int) throws -> [Data] {
        let (image, _) = prepared(original, crop: crop, rotation: rotation, maxDimension: detailedMaxDimension)
        return try bands(of: image, count: detailedBandCount, overlap: detailedOverlap).map { try jpegData($0, quality: 0.9) }
    }

    static func jpegData(_ image: CIImage, quality: CGFloat = jpegQuality) throws -> Data {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let options = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        guard let data = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: options) else {
            throw ImageProcessingError.encodingFailed
        }
        return data
    }

    static func cgImage(_ image: CIImage) -> CGImage? {
        context.createCGImage(image, from: image.extent)
    }

    /// Типы файлов-картинок, которые принимает импорт.
    static func isSupportedImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return [UTType.jpeg, .png, .heic, .heif, .tiff].contains { type.conforms(to: $0) }
    }
}
