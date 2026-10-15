import AppKit
import Foundation
import UniformTypeIdentifiers

/// Превращает то, что пришло из перетаскивания, вставки или Камеры непрерывности, в файлы на диске.
/// «Фото» часто отдаёт не файл, а обещание файла: `loadFileRepresentation` его материализует (SPEC, раздел 3.1).
@MainActor
enum ImportStaging {
    /// Типы, которые принимают перетаскивание и вставка.
    nonisolated static let acceptedTypes: [UTType] = [.fileURL, .image, .pdf]

    /// Временная папка вне iCloud; удаляется после импорта.
    nonisolated static func makeStagingFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Inkling-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Удаляет папки `Inkling-import-*`, оставшиеся от прошлых запусков (приложение закрыли при открытом вопросе
    /// о разделе PDF или оно упало). Свежие не трогает: их могут использовать. Возвращает число удалённых.
    @discardableResult
    nonisolated static func removeStale(in temporary: URL = FileManager.default.temporaryDirectory,
                                        olderThan age: TimeInterval = 24 * 3600, now: Date = Date()) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? []
        var removed = 0
        for name in names where name.hasPrefix("Inkling-import-") {
            let url = temporary.appendingPathComponent(name, isDirectory: true)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, now.timeIntervalSince(modified) > age else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    /// Файлы из провайдеров в исходном порядке. Ссылки на файлы возвращаются как есть, данные копируются в `staging`.
    static func files(from providers: [NSItemProvider], staging: URL) async -> [URL] {
        var urls: [URL] = []
        for (index, provider) in providers.enumerated() {
            if let url = await fileURL(from: provider) {
                urls.append(url)
            } else if let url = await materialize(provider, staging: staging, index: index) {
                urls.append(url)
            }
        }
        return urls
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url?.isFileURL == true ? url : nil)
            }
        }
    }

    /// Копирует данные провайдера (картинку или PDF) в файл. Предпочтение — PDF, затем исходный формат картинки.
    private static func materialize(_ provider: NSItemProvider, staging: URL, index: Int) async -> URL? {
        let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
        guard let type = types.first(where: { $0.conforms(to: .pdf) })
                ?? types.first(where: { $0.conforms(to: .heic) || $0.conforms(to: .jpeg) || $0.conforms(to: .png) })
                ?? types.first(where: { $0.conforms(to: .image) }) else { return nil }
        let suggested = provider.suggestedName.map(FolderNaming.sanitize) ?? "Импорт \(index + 1)"
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { return continuation.resume(returning: nil) }
                // Файл провайдера живёт только внутри обработчика: копируем сразу.
                let ext = url.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "jpg") : url.pathExtension
                let target = staging.appendingPathComponent("\(index)-\(suggested)").appendingPathExtension(ext)
                do {
                    try FileManager.default.copyItem(at: url, to: target)
                    continuation.resume(returning: target)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Файлы из буфера обмена: ссылки на файлы, PDF (сканы Камеры непрерывности) или данные картинки
    /// (в том числе из универсального буфера с iPhone).
    static func files(from pasteboard: NSPasteboard, staging: URL) -> [URL] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls
        }
        let candidates: [(NSPasteboard.PasteboardType, String)] = [
            (.pdf, "pdf"),
            (NSPasteboard.PasteboardType(UTType.heic.identifier), "heic"),
            (NSPasteboard.PasteboardType(UTType.jpeg.identifier), "jpg"),
            (.png, "png"),
            (.tiff, "tiff"),
        ]
        for (type, ext) in candidates {
            if let data = pasteboard.data(forType: type) {
                let target = staging.appendingPathComponent("Вставка-\(UUID().uuidString.prefix(8))").appendingPathExtension(ext)
                if (try? data.write(to: target)) != nil { return [target] }
            }
        }
        return []
    }
}
