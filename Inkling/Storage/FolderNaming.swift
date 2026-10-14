import Foundation

/// Имена папок предметов и лекций (SPEC, разделы 6 и 13).
enum FolderNaming {
    static let maxNameLength = 120
    static let untitled = "Без названия"

    /// Делает из пользовательского текста допустимое имя папки:
    /// `/` и `:` заменяются, пробелы по краям и точки в начале убираются, длина ограничивается.
    static func sanitize(_ raw: String) -> String {
        var name = raw.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        name = name.components(separatedBy: .newlines).joined(separator: " ")
        name = name.trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.count > maxNameLength {
            name = String(name.prefix(maxNameLength)).trimmingCharacters(in: .whitespaces)
        }
        return name.isEmpty ? untitled : name
    }

    /// `ГГГГ-ММ-ДД — Тема`.
    static func lectureFolderName(date: CalendarDate, topic: String) -> String {
        "\(date) — \(sanitize(topic))"
    }

    /// Возвращает свободный путь `base`, `base (2)`, `base (3)`… в папке `directory`.
    /// `excluding` — текущее место самой переименовываемой папки: оно считается свободным.
    static func uniqueURL(in directory: URL, baseName: String, excluding: URL? = nil,
                          exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        var index = 1
        while true {
            let name = index == 1 ? baseName : "\(baseName) (\(index))"
            let candidate = directory.appendingPathComponent(name, isDirectory: true)
            if let excluding, samePath(candidate, excluding) { return candidate }
            if !exists(candidate) { return candidate }
            index += 1
        }
    }

    /// Сравнение путей без учёта регистра и нормализации Юникода, как в APFS по умолчанию.
    static func samePath(_ a: URL, _ b: URL) -> Bool {
        normalized(a.standardizedFileURL.path) == normalized(b.standardizedFileURL.path)
    }

    static func sameName(_ a: String, _ b: String) -> Bool {
        normalized(a) == normalized(b)
    }

    private static func normalized(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.lowercased()
    }
}
