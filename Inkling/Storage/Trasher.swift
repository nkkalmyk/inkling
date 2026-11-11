import Foundation

/// Удаление в корзину. В тестах подменяется, чтобы не трогать настоящую корзину.
protocol Trasher: Sendable {
    func trash(_ url: URL) throws
}

/// Корзина macOS. Для папки в iCloud Drive система переносит файлы в корзину iCloud, и приложению без доступа
/// к iCloud Drive она может отказать («нет прав доступа»). Тогда файлы переносятся в `_Удалённое/<метка>/`
/// внутри папки хранения: данные не теряются, а приложение эту папку не показывает.
struct SystemTrasher: Trasher {
    static let fallbackFolderName = "_Удалённое"

    var fallbackRoot: URL?

    func trash(_ url: URL) throws {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            guard let fallbackRoot else { throw error }
            try Self.moveAside(url, into: fallbackRoot)
        }
    }

    static func moveAside(_ url: URL, into root: URL, now: Date = Date()) throws {
        let folder = root.appendingPathComponent(fallbackFolderName, isDirectory: true)
            .appendingPathComponent(HistoryStore.stamp(now), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
    }
}
