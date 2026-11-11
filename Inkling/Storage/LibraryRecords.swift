import Foundation

/// Лекция, найденная на диске.
struct LectureRecord: Identifiable, Equatable, Sendable {
    var meta: LectureMeta
    var folder: URL
    /// У `meta.json` есть конфликтные копии iCloud.
    var hasConflict: Bool = false

    var id: UUID { meta.id }
}

/// Папка лекции, которую пока нельзя показать.
struct UnavailableLecture: Identifiable, Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        /// `meta.json` выгружен в iCloud и скачивается.
        case downloading
        /// `meta.json` не читается.
        case unreadable(String)
    }

    var folder: URL
    var reason: Reason

    var id: String { folder.path }
    var name: String { folder.lastPathComponent }
}

struct SubjectRecord: Identifiable, Equatable, Sendable {
    var name: String
    var folder: URL
    var lectures: [LectureRecord] = []
    var unavailable: [UnavailableLecture] = []

    var id: String { name }
}

enum LibraryError: LocalizedError, Equatable {
    case subjectExists(String)
    case subjectNotFound(String)
    case lectureNotFound
    case emptyName

    var errorDescription: String? {
        switch self {
        case .subjectExists(let name): "Предмет «\(name)» уже есть."
        case .subjectNotFound(let name): "Предмет «\(name)» не найден. Возможно, папку переименовали или удалили в Finder."
        case .lectureNotFound: "Лекция не найдена. Возможно, папку переименовали или удалили в Finder."
        case .emptyName: "Название не может быть пустым."
        }
    }
}
