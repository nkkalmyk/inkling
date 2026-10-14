import Foundation

/// Чтение и запись с координацией файлов (папка может синхронизироваться с iCloud).
/// Запись атомарная: данные пишутся во временный файл рядом и подменяют исходный (SPEC, раздел 6).
enum AtomicFile {
    static func write(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do {
                try data.write(to: target, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let error = coordinationError ?? writeError { throw error }
    }

    static func read(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { source in
            result = Result { try Data(contentsOf: source) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        var data = try JSONCoding.makeEncoder().encode(value)
        data.append(0x0A)
        try write(data, to: url)
    }

    static func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONCoding.makeDecoder().decode(type, from: read(url))
    }
}
