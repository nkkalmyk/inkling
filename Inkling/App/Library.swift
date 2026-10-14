import AppKit
import Foundation
import Observation

/// Состояние библиотеки для интерфейса: предметы, выбранная лекция, открытые диалоги, ошибки.
/// Все изменения файлов идут через `LibraryStore`; после них и после внешних изменений папка перечитывается.
@MainActor
@Observable
final class Library {
    enum Sheet: Identifiable, Equatable {
        case newLecture(subject: String?)
        case editLecture(UUID)
        case newSubject
        case renameSubject(String)

        var id: String {
            switch self {
            case .newLecture(let subject): "newLecture-\(subject ?? "")"
            case .editLecture(let id): "editLecture-\(id)"
            case .newSubject: "newSubject"
            case .renameSubject(let name): "renameSubject-\(name)"
            }
        }
    }

    enum Deletion: Identifiable, Equatable {
        case lecture(UUID, title: String)
        case subject(String, lectureCount: Int)

        var id: String {
            switch self {
            case .lecture(let id, _): "lecture-\(id)"
            case .subject(let name, _): "subject-\(name)"
            }
        }
    }

    private(set) var subjects: [SubjectRecord] = []
    private(set) var store: LibraryStore
    var selection: UUID?
    var sheet: Sheet?
    var pendingDeletion: Deletion?
    var errorMessage: String?

    private var watcher: DirectoryWatcher?
    private var downloadPoll: Task<Void, Never>?

    init(root: URL, trasher: any Trasher = SystemTrasher()) {
        store = LibraryStore(root: root, trasher: trasher)
    }

    var root: URL { store.root }

    var subjectNames: [String] { subjects.map(\.name) }

    var selectedLecture: LectureRecord? {
        guard let selection else { return nil }
        return lecture(id: selection)
    }

    func lecture(id: UUID) -> LectureRecord? {
        subjects.lazy.flatMap(\.lectures).first { $0.id == id }
    }

    // MARK: Открытие и перечитывание

    /// Открывает папку хранения (создаёт её со стартовыми предметами при первом запуске) и начинает следить за ней.
    func open(root newRoot: URL) {
        watcher?.stop()
        watcher = nil
        store = LibraryStore(root: newRoot, trasher: store.trasher)
        perform { try store.bootstrap() }
        reload()
        watcher = DirectoryWatcher(url: newRoot) { [weak self] in self?.reload() }
    }

    func reload() {
        do {
            subjects = try store.loadSubjects()
        } catch {
            errorMessage = "Не удалось прочитать папку «\(store.root.path)»: \(error.localizedDescription)"
            subjects = []
        }
        if let selection, lecture(id: selection) == nil { self.selection = nil }
        scheduleDownloadPollIfNeeded()
    }

    /// Пока есть лекции, выгруженные в iCloud, периодически перечитываем папку.
    private func scheduleDownloadPollIfNeeded() {
        let waiting = subjects.contains { $0.unavailable.contains { $0.reason == .downloading } }
        guard waiting, downloadPoll == nil else { return }
        downloadPoll = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            self.downloadPoll = nil
            self.reload()
        }
    }

    // MARK: Действия

    func createSubject(named name: String) -> Bool {
        perform { try store.createSubject(named: name) } != nil
    }

    func renameSubject(_ oldName: String, to newName: String) -> Bool {
        perform { try store.renameSubject(oldName, to: newName) } != nil
    }

    func createLecture(subject: String, topic: String, date: CalendarDate) -> Bool {
        guard let record = perform({ try store.createLecture(subject: subject, topic: topic, date: date) }) else {
            return false
        }
        selection = record.id
        return true
    }

    func updateLecture(id: UUID, subject: String, topic: String, date: CalendarDate) -> Bool {
        perform { try store.updateLecture(id: id, subject: subject, topic: topic, date: date) } != nil
    }

    func requestDeleteLecture(_ id: UUID) {
        guard let lecture = lecture(id: id) else { return }
        pendingDeletion = .lecture(id, title: lecture.meta.topic)
    }

    func requestDeleteSubject(_ name: String) {
        let count = subjects.first { $0.name == name }?.lectures.count ?? 0
        pendingDeletion = .subject(name, lectureCount: count)
    }

    func confirmDeletion(_ deletion: Deletion) {
        switch deletion {
        case .lecture(let id, _):
            if perform({ try store.deleteLecture(id: id) }) != nil, selection == id { selection = nil }
        case .subject(let name, _):
            perform { try store.deleteSubject(name) }
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Выполняет файловую операцию, показывает ошибку по-русски и перечитывает библиотеку.
    @discardableResult
    private func perform<T>(_ action: () throws -> T) -> T? {
        defer { reload() }
        do {
            return try action()
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
