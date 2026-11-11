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
        /// Страницы лекции; `edited` — среди них есть текст, правленный вручную.
        case pages(Set<String>, lectureID: UUID, edited: Bool)

        var id: String {
            switch self {
            case .lecture(let id, _): "lecture-\(id)"
            case .subject(let name, _): "subject-\(name)"
            case .pages(let ids, let lectureID, _): "pages-\(lectureID)-\(ids.sorted().joined(separator: ","))"
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
    /// Вкладка, на которой открыть следующую выбранную лекцию (`openLecture`); `LectureView` забирает её при появлении.
    var requestedTab: LectureTab?
    /// Раздел конспекта, к которому прокрутить при открытии (`openLecture`); снимается, когда конспект прокручен.
    var requestedAnchor: AnchorRequest?

    struct AnchorRequest: Equatable {
        var lecture: UUID
        var anchor: String
    }
    var sheet: Sheet?
    var pendingDeletion: Deletion?
    var errorMessage: String?

    // Источники (Library+Sources.swift).
    var importProgress: ImportProgress?
    /// Импорты одной лекции идут по очереди: первый может переименовать папку (дата по фото), и второй,
    /// запомнивший старый путь, писал бы в папку-призрак без `meta.json` (аудит 2026-11).
    @ObservationIgnored var importChains: [UUID: Task<Void, Never>] = [:]
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
    /// Лекции ушли в корзину: их распознавание, сборку и материалы нужно остановить, иначе вызовы модели
    /// тратят лимит до конца, а результат выбрасывается. Задаёт приложение, где известны все центры.
    @ObservationIgnored var onLecturesDeleted: @MainActor ([UUID]) -> Void = { _ in }

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
        // Одно чтение библиотеки на запуск: через `perform` каждый шаг перечитывал бы все `meta.json` (аудит 2026-11).
        do { try store.bootstrap() } catch { errorMessage = error.localizedDescription }
        do { try prompts.installMissingDefaults() } catch { errorMessage = error.localizedDescription }
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
            // Без изменений не трогаем наблюдаемое свойство: иначе каждое событие FSEvents перерисовывало бы
            // сайдбар, список лекций и вкладки.
            if loaded != subjects { subjects = loaded }
            if let selection, lecture(id: selection) == nil { self.selection = nil }
            scheduleDownloadPollIfNeeded()
        }
    }

    func reload() {
        reloadGeneration &+= 1
        do {
            let loaded = try store.loadSubjects()
            if loaded != subjects { subjects = loaded }
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

    /// Удаление страниц из интерфейса (⌫, меню, «Удалить выбранные»). Одна страница без ручной правки удаляется сразу:
    /// её текст можно распознать заново, и всё равно всё уходит в корзину. Несколько страниц или ручная правка —
    /// после подтверждения (решение владельца, аудит 2026-11).
    func requestDeletePages(_ ids: Set<String>, lectureID: UUID) {
        guard !ids.isEmpty, let lecture = lecture(id: lectureID) else { return }
        let edited = ids.contains { lecture.meta.pageText($0)?.manuallyEdited == true }
        if ids.count == 1 && !edited {
            deletePages(ids, lectureID: lectureID)
        } else {
            pendingDeletion = .pages(ids, lectureID: lectureID, edited: edited)
        }
    }

    func requestDeleteSubject(_ name: String) {
        let count = subjects.first { $0.name == name }?.lectures.count ?? 0
        pendingDeletion = .subject(name, lectureCount: count)
    }

    func confirmDeletion(_ deletion: Deletion) {
        switch deletion {
        case .lecture(let id, _):
            guard perform({ try store.deleteLecture(id: id) }) != nil else { return }
            if selection == id { selection = nil }
            onLecturesDeleted([id])
        case .subject(let name, _):
            let ids = subjects.first { $0.name == name }?.lectures.map(\.id) ?? []
            guard perform({ try store.deleteSubject(name) }) != nil else { return }
            onLecturesDeleted(ids)
        case .pages(let ids, let lectureID, _):
            deletePages(ids, lectureID: lectureID)
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
