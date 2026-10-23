import Foundation
import PDFKit

/// Индексатор учебников: проходит PDF постранично (текстовый слой или Vision), складывает текст в `LiteratureStore`.
/// Прогресс сохраняется пачками, поэтому повторный запуск продолжает с места остановки, а неизменённые книги пропускает.
actor LiteratureIndexer {
    struct Book: Sendable, Equatable {
        var url: URL
        var subject: String
    }

    struct Progress: Sendable, Equatable {
        var title: String
        var bookNumber: Int
        var bookCount: Int
        var pagesDone: Int
        var pagesTotal: Int
        var ocrPages: Int
    }

    struct Summary: Sendable, Equatable {
        var indexedBooks = 0
        var skippedBooks: [String] = []
        var newPages = 0
        var ocrPages = 0
    }

    private let store: LiteratureStore
    private let workers: Int
    private let batchSize = 20

    init(store: LiteratureStore, workers: Int = 4) {
        self.store = store
        self.workers = max(workers, 1)
    }

    static func title(of url: URL) -> String {
        url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    func index(_ books: [Book], progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> Summary {
        var summary = Summary()
        for (number, book) in books.enumerated() {
            try Task.checkCancellation()
            let title = Self.title(of: book.url)
            guard ICloud.availability(of: book.url) == .local else {
                summary.skippedBooks.append("\(title): файл не скачан из iCloud")
                continue
            }
            guard let document = PDFDocument(url: book.url), !document.isLocked, document.pageCount > 0 else {
                summary.skippedBooks.append("\(title): не открывается или защищён паролем")
                continue
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: book.url.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let pageCount = document.pageCount
            let id = try await store.upsertBook(path: book.url.path, title: title, subject: book.subject, size: size, mtime: mtime,
                                                pages: pageCount)
            let done = try await store.indexedPages(book: id)
            let missing = (0..<pageCount).filter { !done.contains($0 + 1) }
            var finished = done.count
            var ocrCount = 0
            progress(Progress(title: title, bookNumber: number + 1, bookCount: books.count, pagesDone: finished,
                              pagesTotal: pageCount, ocrPages: 0))
            if !missing.isEmpty {
                try await store.setStatus(book: id, "индексируется")
                // Страницы режутся на последовательные пачки; одновременно обрабатывается не больше `workers` пачек.
                let chunks = stride(from: 0, to: missing.count, by: batchSize).map { Array(missing[$0..<min($0 + batchSize, missing.count)]) }
                let url = book.url
                try await withThrowingTaskGroup(of: [(number: Int, text: String, method: String)].self) { group in
                    var next = 0
                    func launch() {
                        guard next < chunks.count else { return }
                        let chunk = chunks[next]
                        next += 1
                        group.addTask { Self.extract(chunk, from: url) }
                    }
                    for _ in 0..<workers { launch() }
                    for try await batch in group {
                        try await store.add(pages: batch, book: id)
                        finished += batch.count
                        let ocr = batch.filter { $0.method == "ocr" }.count
                        ocrCount += ocr
                        summary.newPages += batch.count
                        summary.ocrPages += ocr
                        progress(Progress(title: title, bookNumber: number + 1, bookCount: books.count, pagesDone: finished,
                                          pagesTotal: pageCount, ocrPages: ocrCount))
                        if Task.isCancelled { group.cancelAll() } else { launch() }
                    }
                }
            }
            try Task.checkCancellation()
            try await store.setStatus(book: id, "готово")
            summary.indexedBooks += 1
        }
        return summary
    }

    /// Текст страниц пачки (индексы с нуля); работает в своём потоке со своим `PDFDocument`.
    private static func extract(_ indices: [Int], from url: URL) -> [(number: Int, text: String, method: String)] {
        guard let document = PDFDocument(url: url) else { return [] }
        var results: [(number: Int, text: String, method: String)] = []
        for index in indices {
            if Task.isCancelled { break }
            guard let page = document.page(at: index) else { continue }
            let extracted = PageTextExtractor.extract(page)
            results.append((index + 1, extracted.text, extracted.method))
        }
        return results
    }
}
