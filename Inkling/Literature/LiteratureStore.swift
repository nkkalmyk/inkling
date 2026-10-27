import Foundation

/// Выдержка из учебника: страница, найденная поиском.
struct LiteraturePassage: Equatable, Sendable {
    var book: String
    var page: Int
    var text: String
    var score: Double
}

/// Состояние книги в индексе (для настроек).
struct LiteratureBookInfo: Equatable, Sendable, Identifiable {
    var id: Int64
    var path: String
    var title: String
    var subject: String
    var pages: Int
    var indexedPages: Int
    var ocrPages: Int
    var status: String

    var isComplete: Bool { pages > 0 && indexedPages >= pages }
}

/// Индекс учебников: SQLite с полнотекстовым поиском FTS5. Лежит в Application Support, вне iCloud.
/// Таблица `pages` хранит исходный текст страницы, `fts` — нормальные формы слов (`RussianNormalizer`).
actor LiteratureStore {
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inkling", isDirectory: true)
            .appendingPathComponent("Literature", isDirectory: true)
            .appendingPathComponent("index.sqlite")
    }

    private let database: SQLiteDatabase

    /// Индекс в памяти (для тестов).
    static func inMemory() throws -> LiteratureStore { try LiteratureStore(path: ":memory:") }

    init(url: URL = LiteratureStore.defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try self.init(path: url.path)
    }

    private init(path: String) throws {
        database = try SQLiteDatabase(path: path)
        try database.execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")
        try database.execute("""
        CREATE TABLE IF NOT EXISTS books(
            id INTEGER PRIMARY KEY, path TEXT UNIQUE NOT NULL, title TEXT NOT NULL, subject TEXT NOT NULL,
            size INTEGER NOT NULL, mtime REAL NOT NULL, pages INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT '');
        CREATE TABLE IF NOT EXISTS pages(
            book INTEGER NOT NULL, page INTEGER NOT NULL, text TEXT NOT NULL, method TEXT NOT NULL,
            PRIMARY KEY(book, page)) WITHOUT ROWID;
        CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(norm, book UNINDEXED, page UNINDEXED, tokenize = 'unicode61 remove_diacritics 2');
        CREATE VIRTUAL TABLE IF NOT EXISTS fts_vocab USING fts5vocab(fts, row);
        """)
        // Версия разбора страниц (добавлена позже): у старых баз столбца нет.
        try? database.execute("ALTER TABLE books ADD COLUMN version INTEGER NOT NULL DEFAULT 1")
    }

    // MARK: Книги

    /// Находит или создаёт запись книги. Если файл изменился (размер или дата), прежние страницы удаляются.
    func upsertBook(path: String, title: String, subject: String, size: Int64, mtime: Double, pages: Int) throws -> Int64 {
        var existing: (id: Int64, size: Int64, mtime: Double, version: Int64)?
        try database.run("SELECT id, size, mtime, version FROM books WHERE path = ?", [.text(path)]) { row in
            existing = (row.int(0), row.int(1), row.double(2), row.int(3))
        }
        if let existing {
            if existing.size != size || abs(existing.mtime - mtime) > 1 {
                try removePages(book: existing.id)
            } else if existing.version < Int64(PageTextExtractor.version) {
                // Разбор улучшен: страницы с текстовым слоем перечитываются, распознанные сканы остаются.
                try removePages(book: existing.id, method: "layer")
            }
            try database.run("UPDATE books SET title = ?, subject = ?, size = ?, mtime = ?, pages = ?, version = ? WHERE id = ?",
                             [.text(title), .text(subject), .int(size), .double(mtime), .int(Int64(pages)),
                              .int(Int64(PageTextExtractor.version)), .int(existing.id)])
            return existing.id
        }
        try database.run("INSERT INTO books(path, title, subject, size, mtime, pages, version) VALUES(?, ?, ?, ?, ?, ?, ?)",
                         [.text(path), .text(title), .text(subject), .int(size), .double(mtime), .int(Int64(pages)),
                          .int(Int64(PageTextExtractor.version))])
        var id: Int64 = 0
        try database.run("SELECT id FROM books WHERE path = ?", [.text(path)]) { id = $0.int(0) }
        return id
    }

    func setStatus(book: Int64, _ status: String) throws {
        try database.run("UPDATE books SET status = ? WHERE id = ?", [.text(status), .int(book)])
    }

    func removeBook(path: String) throws {
        var id: Int64?
        try database.run("SELECT id FROM books WHERE path = ?", [.text(path)]) { id = $0.int(0) }
        guard let id else { return }
        try removePages(book: id)
        try database.run("DELETE FROM books WHERE id = ?", [.int(id)])
    }

    func clear() throws {
        try database.execute("DELETE FROM pages; DELETE FROM fts; DELETE FROM books;")
    }

    private func removePages(book: Int64, method: String? = nil) throws {
        if let method {
            try database.run("DELETE FROM fts WHERE book = ? AND page IN (SELECT page FROM pages WHERE book = ? AND method = ?)",
                             [.int(book), .int(book), .text(method)])
            try database.run("DELETE FROM pages WHERE book = ? AND method = ?", [.int(book), .text(method)])
        } else {
            try database.run("DELETE FROM pages WHERE book = ?", [.int(book)])
            try database.run("DELETE FROM fts WHERE book = ?", [.int(book)])
        }
    }

    func books() throws -> [LiteratureBookInfo] {
        var result: [LiteratureBookInfo] = []
        try database.run("""
        SELECT b.id, b.path, b.title, b.subject, b.pages, b.status,
               (SELECT COUNT(*) FROM pages p WHERE p.book = b.id),
               (SELECT COUNT(*) FROM pages p WHERE p.book = b.id AND p.method = 'ocr')
        FROM books b ORDER BY b.subject, b.title
        """) { row in
            result.append(LiteratureBookInfo(id: row.int(0), path: row.text(1), title: row.text(2), subject: row.text(3),
                                             pages: Int(row.int(4)), indexedPages: Int(row.int(6)), ocrPages: Int(row.int(7)),
                                             status: row.text(5)))
        }
        return result
    }

    /// Номера страниц книги, которые уже в индексе (для возобновления).
    func indexedPages(book: Int64) throws -> Set<Int> {
        var pages = Set<Int>()
        try database.run("SELECT page FROM pages WHERE book = ?", [.int(book)]) { pages.insert(Int($0.int(0))) }
        return pages
    }

    // MARK: Страницы

    /// Записывает пачку страниц одной транзакцией: так прогресс сохраняется и выход приложения ничего не ломает.
    func add(pages: [(number: Int, text: String, method: String)], book: Int64) throws {
        try database.transaction {
            for page in pages {
                try database.run("INSERT OR REPLACE INTO pages(book, page, text, method) VALUES(?, ?, ?, ?)",
                                 [.int(book), .int(Int64(page.number)), .text(page.text), .text(page.method)])
                try database.run("DELETE FROM fts WHERE book = ? AND page = ?", [.int(book), .int(Int64(page.number))])
                try database.run("INSERT INTO fts(norm, book, page) VALUES(?, ?, ?)",
                                 [.text(RussianNormalizer.indexText(page.text)), .int(book), .int(Int64(page.number))])
            }
        }
    }

    // MARK: Поиск

    /// Сколько страниц содержат слово (основу); для оценки редкости слов запроса.
    func documentFrequency(_ term: String) throws -> Int {
        var count = 0
        try database.run("SELECT doc FROM fts_vocab WHERE term = ?", [.text(term)]) { count = Int($0.int(0)) }
        return count
    }

    func totalPages() throws -> Int {
        var count = 0
        try database.run("SELECT COUNT(*) FROM pages") { count = Int($0.int(0)) }
        return count
    }

    /// Лучшие страницы по ранжированию BM25 для основ слов (любое из слов), в пределах предмета.
    func search(terms: [String], subject: String?, limit: Int) throws -> [LiteraturePassage] {
        let usable = terms.filter { $0.allSatisfy { $0.isLetter || $0.isNumber } && !$0.isEmpty }
        guard !usable.isEmpty else { return [] }
        let query = usable.map { "\"\($0)\"" }.joined(separator: " OR ")
        var sql = """
        SELECT b.title, p.page, p.text, bm25(fts) AS score
        FROM fts JOIN pages p ON p.book = fts.book AND p.page = fts.page JOIN books b ON b.id = p.book
        WHERE fts MATCH ?
        """
        var values: [SQLiteDatabase.Value] = [.text(query)]
        if let subject {
            sql += " AND b.subject = ?"
            values.append(.text(subject))
        }
        sql += " ORDER BY score LIMIT ?"
        values.append(.int(Int64(limit)))
        var result: [LiteraturePassage] = []
        try database.run(sql, values) { row in
            result.append(LiteraturePassage(book: row.text(0), page: Int(row.int(1)), text: row.text(2), score: row.double(3)))
        }
        return result
    }
}
