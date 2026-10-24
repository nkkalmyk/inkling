import Foundation
import Testing
@testable import Inkling

/// Индексация настоящих учебников в реальный индекс приложения (по флагу, долго и греет процессор).
/// `INKLING_LIVE_BOOKS` — файл со строками «коллекция|путь к PDF»; прогресс — в `INKLING_LIVE_LOG`.
@Suite("Учебники: живая индексация", .enabled(if: ProcessInfo.processInfo.environment["INKLING_LIVE_INDEX"] == "1"))
struct LiteratureIndexLiveTests {
    @Test func indexesListedBooks() async throws {
        let environment = ProcessInfo.processInfo.environment
        let list = try String(contentsOfFile: try #require(environment["INKLING_LIVE_BOOKS"]), encoding: .utf8)
        let books = list.split(separator: "\n").compactMap { line -> LiteratureIndexer.Book? in
            let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
            return parts.count == 2 ? .init(url: URL(fileURLWithPath: parts[1]), subject: parts[0]) : nil
        }
        let logPath = environment["INKLING_LIVE_LOG"] ?? "/dev/null"
        @Sendable func log(_ text: String) {
            guard let handle = FileHandle(forWritingAtPath: logPath) ?? (FileManager.default.createFile(atPath: logPath, contents: nil)
                ? FileHandle(forWritingAtPath: logPath) : nil) else { return }
            handle.seekToEndOfFile()
            handle.write(Data((text + "\n").utf8))
            try? handle.close()
        }
        let store = try LiteratureStore()
        let started = Date()
        log("Старт: книг \(books.count)")
        let summary = try await LiteratureIndexer(store: store, workers: 4).index(books) { progress in
            if progress.pagesDone % 40 == 0 || progress.pagesDone == progress.pagesTotal {
                log("[\(progress.bookNumber)/\(progress.bookCount)] \(progress.title): \(progress.pagesDone)/\(progress.pagesTotal), распознано \(progress.ocrPages), \(Int(Date().timeIntervalSince(started))) с")
            }
        }
        log("ГОТОВО за \(Int(Date().timeIntervalSince(started))) с: книг \(summary.indexedBooks), страниц \(summary.newPages), OCR \(summary.ocrPages); пропущено: \(summary.skippedBooks)")
        for info in try await store.books() { log("  \(info.subject) | \(info.title) | \(info.indexedPages)/\(info.pages) стр, OCR \(info.ocrPages) | \(info.status)") }
    }
}
