import Foundation

/// Особенности папки, синхронизируемой с iCloud Drive (SPEC, раздел 6).
enum ICloud {
    /// Состояние файла на диске.
    enum Availability: Equatable, Sendable {
        case local
        /// Файл выгружен: на диске только заглушка, нужно скачать.
        case notDownloaded
        case missing
    }

    /// Имя заглушки в старом формате: `meta.json` → `.meta.json.icloud`.
    static func placeholderName(for name: String) -> String { ".\(name).icloud" }

    /// Обратное преобразование: `.meta.json.icloud` → `meta.json`; для обычных имён `nil`.
    static func originalName(fromPlaceholder name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > ".icloud".count + 1 else { return nil }
        return String(name.dropFirst().dropLast(".icloud".count))
    }

    /// Проверяет файл и его заглушку. Новый формат (файл с настоящим именем, но без данных)
    /// распознаётся по `ubiquitousItemDownloadingStatus`.
    static func availability(of url: URL, fileManager: FileManager = .default) -> Availability {
        if fileManager.fileExists(atPath: url.path) {
            let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
            if let values = try? url.resourceValues(forKeys: keys), values.isUbiquitousItem == true,
               let status = values.ubiquitousItemDownloadingStatus, status == .notDownloaded {
                return .notDownloaded
            }
            return .local
        }
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(placeholderName(for: url.lastPathComponent))
        return fileManager.fileExists(atPath: placeholder.path) ? .notDownloaded : .missing
    }

    /// Просит систему скачать файл. Не ждёт окончания: папка перечитывается по событию изменения.
    static func startDownloading(_ url: URL, fileManager: FileManager = .default) {
        try? fileManager.startDownloadingUbiquitousItem(at: url)
    }

    /// Есть ли у файла неразрешённые конфликтные версии iCloud.
    static func hasConflicts(_ url: URL) -> Bool {
        guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) else { return false }
        return !versions.isEmpty
    }
}
