import AppKit
import Foundation
import Observation

/// Выбор в сайдбаре: все лекции или один предмет.
enum LibraryScope: Hashable {
    case all
    case subject(String)
}

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
    /// Что показано в списке лекций: все или одного предмета (выбор в сайдбаре).
    var scope: LibraryScope = .all
    /// Идёт повторение карточек: слой на всё окно (`FlashcardReviewView`), тулбар скрыт.
    var review: FlashcardReview?
    var selection: UUID?
    var sheet: Sheet?
    var pendingDeletion: Deletion?
    var errorMessage: String?

    // Источники (Library+Sources.swift).
    var importProgress: ImportProgress?
    var pdfQuestion: PDFSectionQuestion?
    /// Страницы, которые сейчас пересоздаются.
    var busyPages: Set<String> = []
    /// Растёт при пересоздании файла страницы, чтобы миниатюры перечитались.
    var pageRevisions: [String: Int] = [:]
    /// Растёт при перезаписи `konspekt.md` приложением (сборка, восстановление версии).
    var konspektRevision: [UUID: Int] = [:]
    /// Счётчик правок текстов страниц лекции. Повторная ручная правка не меняет `meta.json`, а сводки
    /// по текстам («Устарело», следующий шаг) должны её заметить.
    var textRevision: [UUID: Int] = [:]
    /// Куда класть снимки Камеры непрерывности и вставку: открытая лекция и выбранный раздел.
    var importTarget: (lectureID: UUID, section: SourceSection)?
    /// Фото, брошенные в окно без открытой лекции (`importIntoWindow`): уйдут в следующую созданную лекцию.
    var pendingImport: PendingImport?
    /// Очередь распознавания; задаётся приложением.
    @ObservationIgnored weak var recognition: RecognitionCenter?

    var prompts: PromptLibrary { PromptLibrary(root: root) }

    private var watcher: DirectoryWatcher?
    private var downloadPoll: Task<Void, Never>?
    @ObservationIgnored private var reloadGeneration = 0

    /// Подменённая корзина (тесты); `nil` — корзина macOS с запасной папкой `_Удалённое`.
    @ObservationIgnored private let customTrasher: (any Trasher)?

    init(root: URL, trasher: (any Trasher)? = nil) {
        customTrasher = trasher
        store = LibraryStore(root: root, trasher: trasher ?? SystemTrasher(fallbackRoot: root))
    }

    var root: URL { store.root }

    var subjectNames: [String] { subjects.map(\.name) }

    /// Предмет для «Новая лекция»: открытой лекции, иначе выбранный в сайдбаре.
    var currentSubject: String? {
        if let subject = selectedLecture?.meta.subject { return subject }
        if case .subject(let name) = scope { return name }
        return nil
    }

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
        store = LibraryStore(root: newRoot, trasher: customTrasher ?? SystemTrasher(fallbackRoot: newRoot))
        perform { try store.bootstrap() }
        perform { try prompts.installMissingDefaults() }
        reload()
        watcher = DirectoryWatcher(url: newRoot) { [weak self] in self?.reloadInBackground() }
    }

    /// Перечитывание по событию файловой системы: чтение и разбор всех `meta.json` идут вне главного потока.
    /// Результат отбрасывается, если за это время состояние уже обновили синхронным `reload()` или сменили папку.
    private func reloadInBackground() {
        let generation = reloadGeneration
        let store = store
        Task {
            let loaded = await Task.detached(priority: .utility) { try? store.loadSubjects() }.value
            guard generation == reloadGeneration, let loaded else { return }
            subjects = loaded
            if let selection, lecture(id: selection) == nil { self.selection = nil }
            scheduleDownloadPollIfNeeded()
        }
    }

    func reload() {
        reloadGeneration &+= 1
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
        if let pending = pendingImport {
            pendingImport = nil
            importFiles(pending.urls, into: .notes, lectureID: record.id, staging: pending.staging)
        }
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
