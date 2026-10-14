import CoreImage
import Foundation
import Testing
@testable import Inkling

@Suite("ImageProcessor")
struct ImageProcessorTests {
    @Test func appliesExifOrientation() throws {
        let dir = try TempDir()
        let url = Fixtures.write(Fixtures.halfRed(width: 400, height: 200), to: dir.url.appendingPathComponent("a.jpg"),
                                 orientation: 6)
        let image = try ImageProcessor.loadOriented(url)
        #expect(image.extent == CGRect(x: 0, y: 0, width: 200, height: 400))
    }

    @Test func convertsHEICToJPEG() throws {
        let dir = try TempDir()
        let url = Fixtures.write(Fixtures.halfRed(), to: dir.url.appendingPathComponent("a.heic"), type: .heic)
        let result = try ImageProcessor.process(try ImageProcessor.loadOriented(url), crop: .original, rotation: 0)
        #expect(result.jpeg.prefix(3) == Data([0xFF, 0xD8, 0xFF]))
        let decoded = try #require(Fixtures.decode(result.jpeg))
        #expect(decoded.width == 400 && decoded.height == 200)
    }

    @Test func downscalesLongSideTo2000() {
        let big = CIImage(cgImage: Fixtures.uniformGray(width: 3000, height: 1500))
        let resized = ImageProcessor.resized(big, maxDimension: 2000)
        #expect(resized.extent.size == CGSize(width: 2000, height: 1000))
        let small = CIImage(cgImage: Fixtures.uniformGray(width: 800, height: 600))
        #expect(ImageProcessor.resized(small, maxDimension: 2000).extent.size == CGSize(width: 800, height: 600))
    }

    @Test func rotatesClockwise() throws {
        let image = CIImage(cgImage: Fixtures.halfRed(width: 400, height: 200))
        let rotated = ImageProcessor.rotated(image, quarterTurns: 1)
        #expect(rotated.extent.size == CGSize(width: 200, height: 400))
        let cg = try #require(ImageProcessor.cgImage(rotated))
        // Красная левая половина после поворота по часовой стрелке оказывается сверху.
        #expect(Fixtures.pixel(cg, x: 100, y: 50).r > 200 && Fixtures.pixel(cg, x: 100, y: 50).g < 60)
        #expect(Fixtures.pixel(cg, x: 100, y: 350).g > 200)
    }

    @Test func rotationWrapsAround() {
        let image = CIImage(cgImage: Fixtures.halfRed(width: 400, height: 200))
        #expect(ImageProcessor.rotated(image, quarterTurns: 4).extent == image.extent)
        #expect(ImageProcessor.rotated(image, quarterTurns: -1).extent.size == CGSize(width: 200, height: 400))
    }

    @Test func detectsPaperAndStraightensIt() throws {
        let photo = CIImage(cgImage: Fixtures.paperOnDesk())
        let quad = try #require(ImageProcessor.detectDocument(in: photo))
        #expect(quad.area > 0.3 && quad.area < 0.6)
        let result = try ImageProcessor.process(photo, crop: .auto(nil), rotation: 0)
        #expect(result.detectedQuad != nil)
        // Лист 1000×760: после выпрямления соотношение сторон близко к исходному.
        let ratio = result.pixelSize.width / result.pixelSize.height
        #expect(abs(ratio - 1000.0 / 760.0) < 0.12)
    }

    @Test func noDocumentInUniformImage() {
        #expect(ImageProcessor.detectDocument(in: CIImage(cgImage: Fixtures.uniformGray())) == nil)
    }

    @Test func savedQuadIsReusedWithoutDetection() throws {
        let photo = CIImage(cgImage: Fixtures.uniformGray(width: 1000, height: 1000))
        let quad = Quad(topLeft: CGPoint(x: 0.1, y: 0.9), topRight: CGPoint(x: 0.6, y: 0.9),
                        bottomRight: CGPoint(x: 0.6, y: 0.1), bottomLeft: CGPoint(x: 0.1, y: 0.1))
        let result = try ImageProcessor.process(photo, crop: .auto(quad), rotation: 0)
        #expect(result.detectedQuad == nil)
        #expect(abs(result.pixelSize.width - 500) <= 2 && abs(result.pixelSize.height - 800) <= 2)
    }

    @Test func readsCaptureDateWithOffset() throws {
        let dir = try TempDir()
        let url = Fixtures.write(Fixtures.halfRed(), to: dir.url.appendingPathComponent("a.jpg"),
                                 dateTimeOriginal: "2026:10:12 09:30:00", offset: "+03:00")
        let date = try #require(ImageProcessor.captureDate(of: url))
        #expect(date == ISO8601DateFormatter().date(from: "2026-10-12T06:30:00Z"))
    }

    @Test func captureDateWithoutOffsetUsesLocalTime() {
        let zone = TimeZone(identifier: "Asia/Tokyo")!
        let date = ImageProcessor.parseExifDate("2026:01:02 03:04:05", offset: nil, defaultTimeZone: zone)
        #expect(date == ISO8601DateFormatter().date(from: "2026-01-01T18:04:05Z"))
    }

    @Test func missingCaptureDate() throws {
        let dir = try TempDir()
        let url = Fixtures.write(Fixtures.halfRed(), to: dir.url.appendingPathComponent("a.png"), type: .png)
        #expect(ImageProcessor.captureDate(of: url) == nil)
        #expect(ImageProcessor.parseExifDate("мусор", offset: nil) == nil)
    }

    @Test func supportedImageTypes() {
        for ext in ["jpg", "JPEG", "png", "heic", "heif", "tiff"] {
            #expect(ImageProcessor.isSupportedImage(URL(fileURLWithPath: "/x/a.\(ext)")), "\(ext)")
        }
        for ext in ["pdf", "txt", "docx", ""] {
            #expect(!ImageProcessor.isSupportedImage(URL(fileURLWithPath: "/x/a.\(ext)")), "\(ext)")
        }
    }
}

@Suite("PDFTools")
struct PDFToolsTests {
    @Test func splitsPagesAndReadsTextLayer() throws {
        let dir = try TempDir()
        let url = Fixtures.pdf(pages: ["Окислитель принимает электроны", "Второй слайд", nil],
                               to: dir.url.appendingPathComponent("s.pdf"))
        #expect(try PDFTools.pageCount(url) == 3)
        let texts = try PDFTools.pageTexts(url)
        #expect(texts[0].contains("Окислитель"))
        #expect(texts[2].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func guessesSlidesByTextLayer() throws {
        let dir = try TempDir()
        let slides = Fixtures.pdf(pages: Array(repeating: "Основные понятия: окислитель, восстановитель, степень окисления", count: 3),
                                  to: dir.url.appendingPathComponent("slides.pdf"))
        let scan = Fixtures.pdf(pages: [nil, nil], to: dir.url.appendingPathComponent("scan.pdf"))
        #expect(try PDFTools.guessSection(slides) == .slides)
        #expect(try PDFTools.guessSection(scan) == .notes)
    }

    @Test func rendersPageAt200dpi() throws {
        let dir = try TempDir()
        let url = Fixtures.pdf(pages: ["x"], to: dir.url.appendingPathComponent("s.pdf"))
        let image = try PDFTools.renderPage(url, index: 0)
        #expect(image.extent.size == CGSize(width: 2667, height: 1500))
        #expect(throws: PDFToolsError.self) { try PDFTools.renderPage(url, index: 5) }
    }

    @Test func unreadablePDF() throws {
        let dir = try TempDir()
        let url = dir.url.appendingPathComponent("broken.pdf")
        try Data("не pdf".utf8).write(to: url)
        #expect(throws: PDFToolsError.self) { try PDFTools.pageCount(url) }
    }
}

@Suite("SlideTextHeuristic")
struct SlideTextHeuristicTests {
    @Test func normalTextUsesTextLayer() {
        let text = """
        Окислительно-восстановительные реакции
        • Окислитель принимает электроны
        • Восстановитель отдаёт электроны
        • Степень окисления — условный заряд атома
        """
        #expect(SlideTextHeuristic.analyze(text) == .init(needsImage: false, reason: nil))
    }

    @Test(arguments: [("", "нет текстового слоя"), ("Спасибо за внимание!", "текста почти нет")])
    func almostNoText(_ text: String, _ reason: String) {
        #expect(SlideTextHeuristic.analyze(text) == .init(needsImage: true, reason: reason))
    }

    @Test func garbageGlyphs() {
        let text = "Теорема о среднем значении \u{FFFD}\u{FFFD} функции \u{E001}\u{E002}\u{E003} на отрезке выполняется"
        #expect(SlideTextHeuristic.analyze(text).needsImage)
        #expect(SlideTextHeuristic.analyze(text).reason == "нераспознанные символы в текстовом слое")
    }

    @Test func formulaHeavySlide() {
        let text = "Ряд Тейлора: f(x) = ∑ f⁽ⁿ⁾(a)/n! · (x − a)ⁿ, ∫ₐᵇ f(x) dx = F(b) − F(a), α + β = γ, x ≤ ε ≥ δ"
        #expect(SlideTextHeuristic.analyze(text) == .init(needsImage: true, reason: "формулы"))
    }

    @Test func brokenFragments() {
        let text = "Предел последовательности и его свойства\nx\nn\n→\n∞\na\n1\nlim\nОпределение предела по Коши"
        #expect(SlideTextHeuristic.analyze(text).needsImage)
    }
}
