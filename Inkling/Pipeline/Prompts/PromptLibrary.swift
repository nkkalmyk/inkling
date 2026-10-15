import Foundation

enum PromptError: LocalizedError {
    case missingTemplate(String)

    var errorDescription: String? {
        switch self {
        case .missingTemplate(let name): "Нет файла промпта «\(name)» ни в папке промптов, ни в приложении."
        }
    }
}

/// Промпты в `<папка хранения>/_prompts/` (SPEC, раздел 5). Читаются перед каждым запросом,
/// поэтому правки пользователя действуют сразу.
struct PromptLibrary: Sendable {
    static let folderName = "_prompts"
    static let backupFolderName = "_старые"

    let folder: URL
    var bundled: URL? = Bundle.main.url(forResource: "Prompts", withExtension: nil)

    init(root: URL) {
        folder = root.appendingPathComponent(Self.folderName, isDirectory: true)
    }

    // MARK: Установка

    /// Копирует недостающие файлы по умолчанию. Существующие файлы не трогает.
    func installMissingDefaults() throws {
        guard let bundled else { return }
        for relative in try Self.files(in: bundled) {
            let target = folder.appendingPathComponent(relative)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: bundled.appendingPathComponent(relative), to: target)
        }
    }

    /// «Сбросить к умолчанию»: изменённые файлы переносятся в `_старые/<дата>/`, затем ставятся исходные.
    /// Возвращает папку с сохранёнными версиями или `nil`, если ничего не менялось.
    @discardableResult
    func resetToDefaults(now: Date = Date()) throws -> URL? {
        guard let bundled else { return nil }
        let backup = folder.appendingPathComponent(Self.backupFolderName, isDirectory: true)
            .appendingPathComponent(HistoryStore.stamp(now), isDirectory: true)
        var backedUp = false
        for relative in try Self.files(in: bundled) {
            let source = bundled.appendingPathComponent(relative)
            let target = folder.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: target.path) {
                if FileManager.default.contentsEqual(atPath: source.path, andPath: target.path) { continue }
                let saved = backup.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: target, to: saved)
                backedUp = true
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: target)
        }
        return backedUp ? backup : nil
    }

    private static func files(in folder: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        else { return [] }
        let base = folder.standardizedFileURL.path
        var result: [String] = []
        for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            result.append(String(url.standardizedFileURL.path.dropFirst(base.count + 1)))
        }
        return result.sorted()
    }

    // MARK: Чтение

    /// Текст шаблона из папки промптов; если файла нет — из приложения.
    func template(_ name: String) throws -> String {
        for base in [folder, bundled].compactMap({ $0 }) {
            let url = base.appendingPathComponent(name)
            if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        }
        throw PromptError.missingTemplate(name)
    }

    /// Вставка `subjects/<Предмет>.md`; если файла нет — пусто.
    func subjectInsert(_ subject: String) -> String {
        let url = folder.appendingPathComponent("subjects").appendingPathComponent("\(subject).md")
        return ((try? String(contentsOf: url, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Подставляет `{ключ}` за один проход: подставленный текст заново не разбирается,
    /// поэтому `{тема}` внутри конспекта остаётся как есть. Незнакомые подстановки остаются.
    static func render(_ template: String, values: [String: String]) -> String {
        var result = ""
        var rest = template[...]
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            let afterOpen = rest.index(after: open)
            if let close = rest[afterOpen...].firstIndex(of: "}"),
               let value = values[String(rest[afterOpen..<close])] {
                result += value
                rest = rest[rest.index(after: close)...]
            } else {
                result.append("{")
                rest = rest[afterOpen...]
            }
        }
        result += rest
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Распознавание

    static let recognitionSystemPrompt = """
    Ты переписываешь фотографии рукописных конспектов и слайды лекций в Markdown. \
    Изображение читай инструментом Read по указанному имени файла. Ничего не придумывай. \
    В ответе выведи только Markdown страницы, без вступлений и пояснений.
    """

    func recognitionPrompt(section: SourceSection, subject: String, topic: String, imageName: String) throws -> String {
        let name = section == .notes ? "recognize.md" : "recognize-slide.md"
        let body = Self.render(try template(name), values: [
            "предмет": subject,
            "тема": topic,
            "вставка_предмета": subjectInsert(subject),
        ])
        return body + "\n\nИзображение: ./\(imageName)"
    }
}
