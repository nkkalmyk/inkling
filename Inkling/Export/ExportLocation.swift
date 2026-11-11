import Foundation

/// Куда падают экспортированные PDF: «Документы → Конспекты». Папка создаётся при первом экспорте.
enum ExportLocation {
    static let pdfFolderName = "Конспекты"

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents", isDirectory: true)
    }

    /// `Тема — Предмет — ГГГГ-ММ-ДД`, тема с большой буквы.
    static func pdfBaseName(subject: String, topic: String, date: CalendarDate) -> String {
        let topic = FolderNaming.sanitize(topic)
        let title = topic.prefix(1).uppercased() + topic.dropFirst()
        return "\(title) — \(FolderNaming.sanitize(subject)) — \(date)"
    }

    /// `Шпаргалка — Тема — Предмет — ГГГГ-ММ-ДД`.
    static func cheatSheetBaseName(subject: String, topic: String, date: CalendarDate) -> String {
        "Шпаргалка — " + pdfBaseName(subject: subject, topic: topic, date: date)
    }

    /// Папка предмета внутри «Конспекты»: название предмета с маленькой буквы («математический анализ»).
    static func subjectFolderName(_ subject: String) -> String {
        FolderNaming.sanitize(subject).lowercased(with: UIFormat.locale)
    }

    /// Путь PDF лекции: `Конспекты/<предмет>/<имя>.pdf`. Повторный экспорт той же лекции заменяет прежний файл.
    static func pdfURL(baseName: String, subject: String, documents: URL = ExportLocation.documents) throws -> URL {
        try url(baseName: baseName, extension: "pdf", subject: subject, documents: documents)
    }

    /// Путь HTML: рядом с PDF, `Конспекты/<предмет>/<имя>.html`.
    static func htmlURL(baseName: String, subject: String, documents: URL = ExportLocation.documents) throws -> URL {
        try url(baseName: baseName, extension: "html", subject: subject, documents: documents)
    }

    private static func url(baseName: String, extension ext: String, subject: String, documents: URL) throws -> URL {
        let folder = documents.appendingPathComponent(pdfFolderName, isDirectory: true)
            .appendingPathComponent(subjectFolderName(subject), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(fitted(baseName, extension: ext)).\(ext)")
    }

    /// Предел имени файла в APFS — 255 байт UTF-8, а кириллица занимает по 2 байта: длинная тема с названием предмета
    /// не помещалась, и экспорт падал без объяснения. Укорачивается начало (тема), хвост «— Предмет — дата» остаётся.
    /// Имена папок лекций (`FolderNaming`) не меняются: иначе существующие папки переименовались бы при следующей записи.
    static func fitted(_ baseName: String, extension ext: String) -> String {
        let limit = maxFileNameBytes - ext.utf8.count - 1
        guard baseName.utf8.count > limit else { return baseName }
        let separator = " — "
        let parts = baseName.components(separatedBy: separator)
        var head = parts.count >= 3 ? parts.dropLast(2).joined(separator: separator) : baseName
        let tail = parts.count >= 3 ? separator + parts.suffix(2).joined(separator: separator) : ""
        while !head.isEmpty, head.utf8.count + "…".utf8.count + tail.utf8.count > limit { head.removeLast() }
        var result = head.trimmingCharacters(in: .whitespaces) + "…" + tail
        while result.utf8.count > limit { result.removeLast() }
        return result
    }

    static let maxFileNameBytes = 255
}
