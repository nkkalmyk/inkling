import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import Inkling

@Suite("Учебники: нормализация и поиск")
struct LiteratureSearchTests {
    @Test func wordFormsShareOneStem() {
        let a = RussianNormalizer.tokens("Теплоты, теплотой; Ёмкость")
        #expect(a == ["теплот", "теплот", "емкост"])
        #expect(RussianNormalizer.tokens("закон Гесса")[0] == "закон")
        #expect(RussianNormalizer.tokens("a b") == [])
    }

    @Test func queryDropsStopwordsAndDuplicates() {
        let q = RussianNormalizer.queryTokens("Это закон, который закон Гесса и теплота при реакции")
        #expect(q == ["закон", "гесса", "теплот", "реакци"])
    }

    @Test func searchFindsPagesByAnyWordForm() async throws {
        let store = try LiteratureStore.inMemory()
        let book = try await store.upsertBook(path: "/b.pdf", title: "Учебник", subject: "Химия", size: 1, mtime: 1, pages: 3)
        try await store.add(pages: [
            (1, "Закон Гесса: тепловой эффект реакции не зависит от пути перехода.", "layer"),
            (2, "Электродный потенциал определяется уравнением Нернста.", "ocr"),
            (3, "Теплоёмкость вещества и теплота нагревания.", "layer"),
        ], book: book)
        let hits = try await store.search(terms: RussianNormalizer.queryTokens("тепловых эффектов реакций по закону Гесса"),
                                          subject: "Химия", limit: 5)
        #expect(hits.first?.page == 1)
        #expect(hits.first?.book == "Учебник")
        #expect(try await store.search(terms: ["нернст"], subject: "Химия", limit: 5).map(\.page) == [2])
        #expect(try await store.search(terms: ["нернст"], subject: "Математика", limit: 5).isEmpty)
        #expect(try await store.search(terms: [], subject: nil, limit: 5).isEmpty)
        #expect(try await store.documentFrequency("нернст") == 1)
        #expect(try await store.totalPages() == 3)
    }

    @Test func changedFileDropsOldPagesAndResumeSkipsDone() async throws {
        let store = try LiteratureStore.inMemory()
        let id = try await store.upsertBook(path: "/b.pdf", title: "Б", subject: "С", size: 10, mtime: 5, pages: 4)
        try await store.add(pages: [(1, "первая страница про энтальпию", "layer"), (2, "вторая", "layer")], book: id)
        #expect(try await store.indexedPages(book: id) == [1, 2])
        // Тот же файл: страницы остаются (возобновление).
        _ = try await store.upsertBook(path: "/b.pdf", title: "Б", subject: "С", size: 10, mtime: 5, pages: 4)
        #expect(try await store.indexedPages(book: id) == [1, 2])
        // Файл изменился: индекс книги сброшен, в поиске старых страниц нет.
        _ = try await store.upsertBook(path: "/b.pdf", title: "Б", subject: "С", size: 11, mtime: 9, pages: 4)
        #expect(try await store.indexedPages(book: id).isEmpty)
        #expect(try await store.search(terms: ["энтальп"], subject: nil, limit: 3).isEmpty)
        let info = try #require(try await store.books().first)
        #expect(info.pages == 4 && info.indexedPages == 0 && !info.isComplete)
    }
}

@Suite("Учебники: извлечение текста и индексатор")
struct LiteratureIndexerTests {
    private static let layerText = "Первый закон термодинамики: изменение внутренней энергии системы равно сумме теплоты и работы. "
        + String(repeating: "Теплота и работа являются функциями процесса, а не функциями состояния системы. ", count: 3)
    private static let scanText = "Электродный потенциал металла определяется уравнением Нернста и зависит от концентрации ионов."

    /// PDF из двух страниц: текст как слой и «скан» (текст нарисован картинкой, слоя нет).
    private func makePDF(at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        func draw(_ text: String, size: CGFloat) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsContext
            (text as NSString).draw(in: CGRect(x: 40, y: 400, width: 515, height: 380),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState()
        }
        context.beginPDFPage(nil)
        draw(Self.layerText, size: 16)
        context.endPDFPage()

        // Вторая страница: растровая картинка с текстом.
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1190, pixelsHigh: 1684, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1190, height: 1684).fill()
        (Self.scanText as NSString).draw(in: CGRect(x: 80, y: 800, width: 1030, height: 700),
                                         withAttributes: [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        context.beginPDFPage(nil)
        context.draw(try #require(bitmap.cgImage), in: box)
        context.endPDFPage()
        context.closePDF()
    }

    @Test func layerPageIsReadDirectlyAndScanGoesThroughVision() throws {
        let dir = try TempDir()
        let url = dir.url.appendingPathComponent("book.pdf")
        try makePDF(at: url)
        let document = try #require(PDFDocument(url: url))
        #expect(document.pageCount == 2)
        let first = PageTextExtractor.extract(try #require(document.page(at: 0)))
        #expect(first.method == "layer")
        #expect(first.text.lowercased().contains("термодинам"), "\(first.text.prefix(200))")
        let second = PageTextExtractor.extract(try #require(document.page(at: 1)))
        #expect(second.method == "ocr")
        #expect(second.text.lowercased().contains("нернста"))
    }

    @Test func indexerIndexesBothKindsResumesAndFindsThem() async throws {
        let dir = try TempDir()
        let url = dir.url.appendingPathComponent("Учебник_химии.pdf")
        try makePDF(at: url)
        let store = try LiteratureStore.inMemory()
        let indexer = LiteratureIndexer(store: store, workers: 2)
        let summary = try await indexer.index([.init(url: url, subject: "Химия")])
        #expect(summary.indexedBooks == 1 && summary.newPages == 2 && summary.ocrPages == 1 && summary.skippedBooks.isEmpty)

        let info = try #require(try await store.books().first)
        #expect(info.title == "Учебник химии" && info.isComplete && info.ocrPages == 1 && info.status == "готово")
        let hits = try await store.search(terms: RussianNormalizer.queryTokens("уравнение Нернста электродного потенциала"),
                                          subject: "Химия", limit: 3)
        #expect(hits.first?.page == 2)
        #expect(try await store.search(terms: RussianNormalizer.queryTokens("первый закон термодинамики"), subject: nil, limit: 3)
            .first?.page == 1)

        // Повторный запуск ничего не распознаёт заново.
        let again = try await indexer.index([.init(url: url, subject: "Химия")])
        #expect(again.newPages == 0 && again.indexedBooks == 1)
    }

    @Test func missingAndBrokenFilesAreSkippedWithReason() async throws {
        let dir = try TempDir()
        let broken = dir.url.appendingPathComponent("broken.pdf")
        try Data("не pdf".utf8).write(to: broken)
        let store = try LiteratureStore.inMemory()
        let summary = try await LiteratureIndexer(store: store).index([.init(url: broken, subject: "С")])
        #expect(summary.indexedBooks == 0 && summary.skippedBooks.count == 1)
    }
}

@Suite("Учебники: выдержки для лекции")
struct LiteratureRetrievalTests {
    private func store() async throws -> LiteratureStore {
        let store = try LiteratureStore.inMemory()
        let a = try await store.upsertBook(path: "/a", title: "Ахметов", subject: "Химия", size: 1, mtime: 1, pages: 6)
        let e = try await store.upsertBook(path: "/e", title: "Еремин", subject: "Химия", size: 1, mtime: 1, pages: 2)
        let z = try await store.upsertBook(path: "/z", title: "Зорич", subject: "Математика", size: 1, mtime: 1, pages: 1)
        try await store.add(pages: (1...6).map { ($0, "Закон Гесса и энтальпия реакции, тепловой эффект, страница \($0) про термохимию", "ocr") }, book: a)
        try await store.add(pages: [(10, "Энтальпия образования вещества и закон Гесса в учебнике Еремина", "ocr"),
                                    (11, "Совсем другая тема: строение атома и квантовые числа", "ocr")], book: e)
        try await store.add(pages: [(5, "Предел функции и непрерывность, энтальпия не упоминается всерьёз", "layer")], book: z)
        return store
    }

    @Test func queryTermsPreferRareLectureWordsAndSkipUnknownOnes() async throws {
        let store = try await store()
        let terms = try await LiteratureRetrieval.queryTerms(topic: "Закон Гесса", texts: ["энтальпия реакции и абракадабра"], store: store)
        #expect(terms.contains("гесса") && terms.contains("энталь"))
        #expect(!terms.contains("абрака"))
    }

    @Test func passagesAreLimitedPerBookAndStayInCollection() async throws {
        let store = try await store()
        let passages = try await LiteratureRetrieval.passages(collection: "Химия", topic: "Закон Гесса",
                                                              texts: ["энтальпия реакции тепловой эффект"], store: store)
        #expect(!passages.isEmpty)
        #expect(passages.filter { $0.book == "Ахметов" }.count <= LiteratureRetrieval.maxPerBook)
        #expect(passages.contains { $0.book == "Еремин" && $0.page == 10 })
        #expect(!passages.contains { $0.book == "Зорич" })
        #expect(!passages.contains { $0.page == 11 })
    }

    @Test func promptBlockCitesBooksAndPagesAndTreatsExcerptsAsData() {
        let block = LiteratureRetrieval.promptBlock([LiteraturePassage(book: "Ахметов", page: 42, text: "Текст", score: -1)])
        #expect(block.contains("[Ахметов, с. 42]\nТекст"))
        #expect(block.contains("инструкции") && block.contains("## Источники"))
        #expect(LiteratureRetrieval.promptBlock([]).isEmpty)
        #expect(LiteratureRetrieval.references([LiteraturePassage(book: "Б", page: 3, text: "", score: 0)]) == ["Б, с. 3"])
    }

    @MainActor
    @Test func defaultMappingBindsSubjectsToCollections() {
        let map = LiteratureCenter.defaultMapping(["Математика", "Химия"])
        #expect(map["Высшая алгебра"] == "Математика" && map["Математический анализ"] == "Математика")
        #expect(map["Дискретная математика"] == "Математика")
        #expect(map["Общая и неорганическая химия"] == "Химия")
    }
}
