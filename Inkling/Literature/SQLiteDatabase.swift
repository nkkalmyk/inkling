import Foundation
import SQLite3

/// Тонкая обёртка над системной SQLite (без зависимостей). Не потокобезопасна: пользоваться из одного актора.
final class SQLiteDatabase {
    enum Value {
        case int(Int64)
        case double(Double)
        case text(String)
        case null
    }

    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    private var handle: OpaquePointer?

    init(path: String) throws {
        if sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "не удалось открыть базу"
            sqlite3_close(handle)
            throw Failure(message: message)
        }
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit { sqlite3_close(handle) }

    private var lastError: String { handle.map { String(cString: sqlite3_errmsg($0)) } ?? "ошибка SQLite" }

    /// Выполняет один или несколько операторов без параметров.
    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? lastError
            sqlite3_free(error)
            throw Failure(message: message)
        }
    }

    /// Выполняет оператор с параметрами; для каждой строки результата вызывает `row` (столбцы читаются по номерам).
    func run(_ sql: String, _ values: [Value] = [], row: ((Row) -> Void)? = nil) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw Failure(message: lastError) }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .int(let v): sqlite3_bind_int64(statement, position, v)
            case .double(let v): sqlite3_bind_double(statement, position, v)
            case .text(let v): sqlite3_bind_text(statement, position, v, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .null: sqlite3_bind_null(statement, position)
            }
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: row?(Row(statement: statement))
            case SQLITE_DONE: return
            default: throw Failure(message: lastError)
            }
        }
    }

    struct Row {
        fileprivate let statement: OpaquePointer?
        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
        func text(_ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}
