import CoreImage
import Foundation
import Testing
@testable import Inkling

@Suite("Режим «Подробно»: фрагменты страницы")
struct DetailedBandsTests {
    private func image(width: Int, height: Int) -> CIImage {
        CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    @Test func bandsCoverPageTopToBottomWithOverlap() {
        let page = image(width: 1000, height: 3000)
        let bands = ImageProcessor.bands(of: page, count: 3, overlap: 0.2)
        #expect(bands.count == 3)
        // Высота фрагмента: 3000 / (3 - 2·0,2) ≈ 1154, шаг 0,8 высоты.
        for band in bands {
            #expect(band.extent.origin == .zero)
            #expect(band.extent.width == 1000)
            #expect(abs(band.extent.height - 1154) <= 2)
        }
        let total = bands.reduce(0) { $0 + $1.extent.height }
        #expect(total > 3000)  // перекрытие: суммарная высота больше страницы
    }

    @Test func singleBandReturnsWholeImage() {
        let page = image(width: 100, height: 300)
        #expect(ImageProcessor.bands(of: page, count: 1, overlap: 0.2).first?.extent == page.extent)
    }

    @Test func detailedBandsProduceJPEGsFromHugeOriginal() throws {
        let original = image(width: 6000, height: 8000)
        let parts = try ImageProcessor.detailedBands(original, crop: .original, rotation: 0)
        #expect(parts.count == ImageProcessor.detailedBandCount)
        #expect(parts.allSatisfy { $0.starts(with: [0xFF, 0xD8]) })
        // Длинная сторона страницы сжата до 4500, а не до обычных 2000.
        let first = try #require(CIImage(data: parts[0]))
        #expect(first.extent.width > 3000)
    }
}
