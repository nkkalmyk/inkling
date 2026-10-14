import CryptoKit
import Foundation

/// История версий результатов модели (SPEC, раздел 4.1): перед перезаписью текущая версия
/// сохраняется в `history/<категория>/<ключ>/<метка времени>.<расширение>` вместе с описанием `.json`.
struct HistoryStore: Sendable {
    struct Entry: Identifiable, Equatable, Sendable {
        var file: URL
        var date: Date
        var info: PageText?

        var id: String { file.path }
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

    private static var stampFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        return formatter
    }

    /// Сохраняет копию файла. Повтор последней сохранённой версии не дублируется.
    func save(_ file: URL, info: PageText?, now: Date = Date()) throws {
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
            try AtomicFile.writeJSON(info, to: folder.appendingPathComponent("\(stamp).json"))
        }
    }

    /// Версии от новой к старой.
    func entries() -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension != "json" }
            .compactMap { file -> Entry? in
                let stamp = file.deletingPathExtension().lastPathComponent
                guard let date = Self.date(fromStamp: stamp) else { return nil }
                let infoURL = folder.appendingPathComponent("\(stamp).json")
                let info = try? AtomicFile.readJSON(PageText.self, from: infoURL)
                return Entry(file: file, date: date, info: info)
            }
            .sorted { $0.date > $1.date }
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
        return entry.info
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
