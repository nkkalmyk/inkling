import CryptoKit
import Foundation

/// История версий результатов модели (SPEC, раздел 4.1): перед перезаписью текущая версия
/// сохраняется в `history/<категория>/<ключ>/<метка времени>.<расширение>` вместе с описанием `.json`.
struct HistoryStore: Sendable {
    struct Entry: Identifiable, Equatable, Sendable {
        var file: URL
        var date: Date
        /// Описание версии `<метка>.json`, если оно есть.
        var infoFile: URL?

        var id: String { file.path }

        func info<T: Decodable>(_ type: T.Type) -> T? {
            infoFile.flatMap { try? AtomicFile.readJSON(type, from: $0) }
        }
    }

    let folder: URL

    init(lectureFolder: URL, category: String, key: String) {
        folder = lectureFolder.appendingPathComponent("history", isDirectory: true)
            .appendingPathComponent(category, isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
    }

    /// Метка времени для имени файла: сортируется как строка, без двоеточий.
    static func stamp(_ date: Date) -> String {
        stampFormatter.string(from: date)
    }

    static func date(fromStamp stamp: String) -> Date? {
        stampFormatter.date(from: stamp)
    }

    /// Создаётся один раз: `DateFormatter` дорог, а `entries()` вызывает его на каждый файл. Только чтение, поэтому безопасен.
    private nonisolated(unsafe) static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        return formatter
    }()

    /// Сохраняет копию файла. Повтор последней сохранённой версии не дублируется.
    func save<Info: Encodable>(_ file: URL, info: Info?, now: Date = Date()) throws {
        guard let data = try? Data(contentsOf: file) else { return }
        if let latest = entries().first, (try? Data(contentsOf: latest.file)) == data { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var stamp = Self.stamp(now)
        var step = 1
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(stamp).\(file.pathExtension)").path) {
            stamp = Self.stamp(now.addingTimeInterval(0.001 * Double(step)))
            step += 1
        }
        try AtomicFile.write(data, to: folder.appendingPathComponent("\(stamp).\(file.pathExtension)"))
        if let info {
            try AtomicFile.writeJSON(info, to: folder.appendingPathComponent("\(stamp).info.json"))
        }
    }

    /// Версии от новой к старой. Описание версии — `<метка>.info.json`
    /// (ранние версии писали `<метка>.json` рядом с `.md`; они тоже читаются).
    func entries() -> [Entry] {
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        let stampLength = Self.stamp(Date(timeIntervalSince1970: 0)).count
        var byStamp: [String: [String]] = [:]
        for name in names where name.count > stampLength {
            byStamp[String(name.prefix(stampLength)), default: []].append(name)
        }
        var result: [Entry] = []
        for (stamp, files) in byStamp {
            guard let date = Self.date(fromStamp: stamp) else { continue }
            let info = files.first { $0 == "\(stamp).info.json" }
            let content = files.filter { $0 != info }
            // Старый формат: `<метка>.md` + `<метка>.json`, где `.json` — описание.
            let legacyInfo = content.count == 2 && content.contains("\(stamp).json") ? "\(stamp).json" : nil
            guard let file = content.first(where: { $0 != legacyInfo }) else { continue }
            let infoName = info ?? legacyInfo
            result.append(Entry(file: folder.appendingPathComponent(file), date: date,
                                infoFile: infoName.map { folder.appendingPathComponent($0) }))
        }
        return result.sorted { $0.date > $1.date }
    }
}

/// Тексты страниц `<раздел>/pages/<id>.md` с историей версий.
struct PageTextStore: Sendable {
    let paths: LecturePaths

    func url(_ id: String, in section: SourceSection) -> URL { paths.pageText(id, in: section) }

    func read(_ id: String, in section: SourceSection) -> String? {
        try? String(contentsOf: url(id, in: section), encoding: .utf8)
    }

    func history(_ id: String, in section: SourceSection) -> HistoryStore {
        HistoryStore(lectureFolder: paths.folder, category: "pages-\(section.rawValue)", key: id)
    }

    /// Записывает текст. Если файл уже есть и текст отличается, прежняя версия уходит в историю с описанием `previous`
    /// (кроме промежуточных сохранений ручной правки: `saveHistory: false`).
    func write(_ text: String, id: String, in section: SourceSection, previous: PageText?, saveHistory: Bool = true,
               now: Date = Date()) throws {
        let target = url(id, in: section)
        if saveHistory, let existing = read(id, in: section), existing != text {
            try history(id, in: section).save(target, info: previous, now: now)
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicFile.write(Data(text.utf8), to: target)
    }

    /// Восстанавливает версию; текущая сохраняется в историю. Возвращает описание восстановленной версии.
    func restore(_ entry: HistoryStore.Entry, id: String, in section: SourceSection, current: PageText?,
                 now: Date = Date()) throws -> PageText? {
        let text = try String(contentsOf: entry.file, encoding: .utf8)
        try write(text, id: id, in: section, previous: current, now: now)
        return entry.info(PageText.self)
    }
}

enum FileHash {
    /// SHA-256 содержимого файла в hex; `nil`, если файла нет.
    static func sha256(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
