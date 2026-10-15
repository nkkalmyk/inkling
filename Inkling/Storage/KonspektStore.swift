import Foundation

/// `konspekt.md` лекции с историей версий в `history/konspekt/`.
struct KonspektStore: Sendable {
    let folder: URL

    var url: URL { folder.appendingPathComponent("konspekt.md") }
    var history: HistoryStore { HistoryStore(lectureFolder: folder, category: "konspekt", key: "konspekt") }

    func read() -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    /// Записывает конспект; прежняя версия уходит в историю с описанием `previous`
    /// (кроме промежуточных сохранений ручной правки).
    func write(_ text: String, previous: ArtifactInfo?, saveHistory: Bool = true, now: Date = Date()) throws {
        if saveHistory, let existing = read(), existing != text {
            try history.save(url, info: previous, now: now)
        }
        try AtomicFile.write(Data(text.utf8), to: url)
    }

    func restore(_ entry: HistoryStore.Entry, current: ArtifactInfo?, now: Date = Date()) throws -> ArtifactInfo? {
        let text = try String(contentsOf: entry.file, encoding: .utf8)
        try write(text, previous: current, now: now)
        return entry.info(ArtifactInfo.self)
    }
}
