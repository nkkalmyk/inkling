import AppKit
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Генерация тестовых картинок и PDF прямо в тестах.
enum Fixtures {
    typealias Draw = (CGContext, CGSize) -> Void

    static func cgImage(width: Int, height: Int, draw: Draw) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        draw(ctx, CGSize(width: width, height: height))
        return ctx.makeImage()!
    }

    /// Левая половина красная, правая белая.
    static func halfRed(width: Int = 400, height: Int = 200) -> CGImage {
        cgImage(width: width, height: height) { ctx, size in
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))
        }
    }

    /// «Фото листа»: тёмный стол и светлый лист, повёрнутый на несколько градусов.
    static func paperOnDesk(width: Int = 1600, height: Int = 1200) -> CGImage {
        cgImage(width: width, height: height) { ctx, size in
            ctx.setFillColor(CGColor(red: 0.18, green: 0.14, blue: 0.11, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.rotate(by: 0.08)
            let paper = CGRect(x: -500, y: -380, width: 1000, height: 760)
            ctx.setFillColor(CGColor(red: 0.97, green: 0.96, blue: 0.92, alpha: 1))
            ctx.fill(paper)
            ctx.setFillColor(CGColor(red: 0.1, green: 0.15, blue: 0.45, alpha: 1))
            for i in 0..<10 {
                ctx.fill(CGRect(x: -440, y: 300 - CGFloat(i) * 65, width: CGFloat(500 + (i % 3) * 120), height: 10))
            }
        }
    }

    static func uniformGray(width: Int = 800, height: Int = 600) -> CGImage {
        cgImage(width: width, height: height) { ctx, size in
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// Записывает картинку с EXIF-ориентацией и датой съёмки.
    @discardableResult
    static func write(_ image: CGImage, to url: URL, type: UTType = .jpeg, orientation: Int = 1,
                      dateTimeOriginal: String? = nil, offset: String? = nil) -> URL {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        var exif: [CFString: Any] = [:]
        if let dateTimeOriginal { exif[kCGImagePropertyExifDateTimeOriginal] = dateTimeOriginal }
        if let offset { exif[kCGImagePropertyExifOffsetTimeOriginal] = offset }
        let props: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyExifDictionary: exif,
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        precondition(CGImageDestinationFinalize(dest), "Не удалось записать \(url.lastPathComponent)")
        return url
    }

    /// PDF: на каждой странице свой текст (`nil` — страница-картинка без текстового слоя).
    @discardableResult
    static func pdf(pages: [String?], to url: URL, size: CGSize = CGSize(width: 960, height: 540)) -> URL {
        var box = CGRect(origin: .zero, size: size)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        for text in pages {
            ctx.beginPDFPage(nil)
            if let text {
                let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 22)])
                let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed),
                                                     CFRange(location: 0, length: 0),
                                                     CGPath(rect: box.insetBy(dx: 40, dy: 40), transform: nil), nil)
                CTFrameDraw(frame, ctx)
            } else {
                ctx.draw(paperOnDesk(width: 480, height: 270), in: box)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    /// Цвет пикселя (x, y от верхнего левого угла) в 8-битном RGB.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return (Int(p[0]), Int(p[1]), Int(p[2]))
    }

    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
