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

    /// Путь PDF лекции. Повторный экспорт той же лекции заменяет прежний файл.
    static func pdfURL(baseName: String, documents: URL = ExportLocation.documents) throws -> URL {
        let folder = documents.appendingPathComponent(pdfFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(baseName).pdf")
    }
}
