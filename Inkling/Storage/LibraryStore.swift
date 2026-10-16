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

/// Удаление в корзину. В тестах подменяется, чтобы не трогать настоящую корзину.
protocol Trasher: Sendable {
    func trash(_ url: URL) throws
}

/// Корзина macOS. Для папки в iCloud Drive система переносит файлы в корзину iCloud, и приложению без доступа
/// к iCloud Drive она может отказать («нет прав доступа»). Тогда файлы переносятся в `_Удалённое/<метка>/`
/// внутри папки хранения: данные не теряются, а приложение эту папку не показывает.
struct SystemTrasher: Trasher {
    static let fallbackFolderName = "_Удалённое"

    var fallbackRoot: URL?

    func trash(_ url: URL) throws {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            guard let fallbackRoot else { throw error }
            try Self.moveAside(url, into: fallbackRoot)
        }
    }

    static func moveAside(_ url: URL, into root: URL, now: Date = Date()) throws {
        let folder = root.appendingPathComponent(fallbackFolderName, isDirectory: true)
            .appendingPathComponent(HistoryStore.stamp(now), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
    }
}

/// Файловая библиотека: `<корень>/<Предмет>/<ГГГГ-ММ-ДД — Тема>/meta.json` (SPEC, разделы 6 и 13).
struct LibraryStore: Sendable {
    static let metaFileName = "meta.json"
    static let defaultSubjects = ["Общая и неорганическая химия", "Математический анализ", "Высшая алгебра"]

    let root: URL
    var trasher: any Trasher = SystemTrasher()

    private var fileManager: FileManager { .default }

    // MARK: Корень

    /// Создаёт папку хранения. Если её не было, создаёт и стартовые предметы.
    /// Возвращает `true`, если папка создана сейчас.
    @discardableResult
    func bootstrap() throws -> Bool {
        if fileManager.fileExists(atPath: root.path) { return false }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        for subject in Self.defaultSubjects {
            try fileManager.createDirectory(at: root.appendingPathComponent(subject, isDirectory: true),
                                            withIntermediateDirectories: true)
        }
        return true
    }

    // MARK: Чтение

    /// Все предметы с лекциями. Служебные папки (`_prompts` и скрытые) пропускаются.
    func loadSubjects() throws -> [SubjectRecord] {
        try subdirectories(of: root)
            .filter { !$0.lastPathComponent.hasPrefix("_") }
            .map(loadSubject(at:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func loadSubject(at folder: URL) throws -> SubjectRecord {
        var subject = SubjectRecord(name: folder.lastPathComponent, folder: folder)
        for lectureFolder in try subdirectories(of: folder) {
            let metaURL = lectureFolder.appendingPathComponent(Self.metaFileName)
            switch ICloud.availability(of: metaURL) {
            case .missing:
                continue
            case .notDownloaded:
                ICloud.startDownloading(metaURL)
                subject.unavailable.append(UnavailableLecture(folder: lectureFolder, reason: .downloading))
            case .local:
                do {
                    let meta = try readMeta(in: lectureFolder)
                    subject.lectures.append(LectureRecord(meta: meta, folder: lectureFolder,
                                                          hasConflict: ICloud.hasConflicts(metaURL)))
                } catch {
                    subject.unavailable.append(UnavailableLecture(folder: lectureFolder,
                                                                  reason: .unreadable(error.localizedDescription)))
                }
            }
        }
        subject.lectures.sort { lhs, rhs in
            if lhs.meta.date != rhs.meta.date { return lhs.meta.date > rhs.meta.date }
            return lhs.meta.topic.localizedStandardCompare(rhs.meta.topic) == .orderedAscending
        }
        subject.unavailable.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return subject
    }

    func readMeta(in lectureFolder: URL) throws -> LectureMeta {
        try AtomicFile.readJSON(LectureMeta.self, from: lectureFolder.appendingPathComponent(Self.metaFileName))
    }

    func writeMeta(_ meta: LectureMeta, in lectureFolder: URL) throws {
        try AtomicFile.writeJSON(meta, to: lectureFolder.appendingPathComponent(Self.metaFileName))
    }

    /// Ищет лекцию по `id` во всей библиотеке: путь мог измениться снаружи.
    /// Если известна последняя папка лекции (`hint`), сначала проверяется она: одно чтение вместо обхода библиотеки.
    /// Без совпадения обход идёт до первой найденной лекции, без сортировки и без чтения остальных.
    func findLecture(id: UUID, hint: URL? = nil) throws -> LectureRecord? {
        if let hint, let record = lectureRecord(at: hint), record.id == id { return record }
        for subjectFolder in try subdirectories(of: root) where !subjectFolder.lastPathComponent.hasPrefix("_") {
            for lectureFolder in try subdirectories(of: subjectFolder) {
                if let record = lectureRecord(at: lectureFolder), record.id == id { return record }
            }
        }
        return nil
    }

    /// Лекция по папке, если `meta.json` на месте, скачан и читается.
    private func lectureRecord(at lectureFolder: URL) -> LectureRecord? {
        let metaURL = lectureFolder.appendingPathComponent(Self.metaFileName)
        guard ICloud.availability(of: metaURL) == .local,
              let meta = try? readMeta(in: lectureFolder) else { return nil }
        return LectureRecord(meta: meta, folder: lectureFolder, hasConflict: ICloud.hasConflicts(metaURL))
    }

    // MARK: Предметы

    @discardableResult
    func createSubject(named rawName: String) throws -> URL {
        let name = try validName(rawName)
        if let existing = try existingSubjectFolder(named: name) {
            throw LibraryError.subjectExists(existing.lastPathComponent)
        }
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Переименовывает папку предмета и поле `subject` во всех его лекциях.
    func renameSubject(_ oldName: String, to rawNewName: String) throws {
        let newName = try validName(rawNewName)
        guard let folder = try existingSubjectFolder(named: oldName) else { throw LibraryError.subjectNotFound(oldName) }
        if let other = try existingSubjectFolder(named: newName), !FolderNaming.samePath(other, folder) {
            throw LibraryError.subjectExists(other.lastPathComponent)
        }
        let target = root.appendingPathComponent(newName, isDirectory: true)
        if folder.lastPathComponent != newName {
            try moveItem(from: folder, to: target)
        }
        for lecture in try loadSubject(at: target).lectures where lecture.meta.subject != newName {
            var meta = lecture.meta
            meta.subject = newName
            meta.touch()
            try writeMeta(meta, in: lecture.folder)
        }
    }

    /// Отправляет предмет вместе с лекциями в корзину.
    func deleteSubject(_ name: String) throws {
        guard let folder = try existingSubjectFolder(named: name) else { throw LibraryError.subjectNotFound(name) }
        try trasher.trash(folder)
    }

    // MARK: Лекции

    /// Создаёт лекцию; папка предмета создаётся, если её ещё нет.
    func createLecture(subject rawSubject: String, topic rawTopic: String, date: CalendarDate,
                       now: Date = Date()) throws -> LectureRecord {
        let subjectFolder = try subjectFolderCreatingIfNeeded(rawSubject)
        let topic = rawTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else { throw LibraryError.emptyName }
        let folder = FolderNaming.uniqueURL(in: subjectFolder,
                                            baseName: FolderNaming.lectureFolderName(date: date, topic: topic))
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let meta = LectureMeta(subject: subjectFolder.lastPathComponent, topic: topic, date: date, now: now)
        do {
            try writeMeta(meta, in: folder)
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
        return LectureRecord(meta: meta, folder: folder)
    }

    /// Меняет предмет, тему или дату. Папка переименовывается или переносится, `id` не меняется.
    func updateLecture(id: UUID, subject rawSubject: String, topic rawTopic: String, date: CalendarDate,
                       now: Date = Date()) throws -> LectureRecord {
        let topic = rawTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else { throw LibraryError.emptyName }
        return try mutateLecture(id: id, now: now) { meta in
            meta.subject = rawSubject
            meta.topic = topic
            meta.date = date
        }
    }

    /// Читает свежий `meta.json`, применяет изменение и записывает. Если изменились предмет, тема или дата,
    /// папка переносится или переименовывается; `id` не меняется.
    @discardableResult
    func mutateLecture(id: UUID, now: Date = Date(), _ change: (inout LectureMeta) throws -> Void) throws -> LectureRecord {
        guard let current = try findLecture(id: id) else { throw LibraryError.lectureNotFound }
        var meta = current.meta
        try change(&meta)
        meta.id = current.meta.id
        let subjectFolder = try subjectFolderCreatingIfNeeded(meta.subject)
        meta.subject = subjectFolder.lastPathComponent
        meta.topic = meta.topic.trimmingCharacters(in: .whitespacesAndNewlines)
        if meta.topic.isEmpty { meta.topic = current.meta.topic }

        var folder = current.folder
        let baseName = FolderNaming.lectureFolderName(date: meta.date, topic: meta.topic)
        let movesSubject = !FolderNaming.samePath(subjectFolder, current.folder.deletingLastPathComponent())
        if movesSubject || !folderName(current.folder.lastPathComponent, matchesBase: baseName) {
            let target = FolderNaming.uniqueURL(in: subjectFolder, baseName: baseName, excluding: current.folder)
            if target.lastPathComponent != current.folder.lastPathComponent || movesSubject {
                try moveItem(from: current.folder, to: target)
                folder = target
            }
        }

        meta.touch(now)
        try writeMeta(meta, in: folder)
        return LectureRecord(meta: meta, folder: folder)
    }

    func deleteLecture(id: UUID) throws {
        guard let lecture = try findLecture(id: id) else { throw LibraryError.lectureNotFound }
        try trasher.trash(lecture.folder)
    }

    // MARK: Вспомогательное

    private func validName(_ raw: String) throws -> String {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.emptyName }
        return FolderNaming.sanitize(raw)
    }

    private func existingSubjectFolder(named name: String) throws -> URL? {
        let wanted = FolderNaming.sanitize(name)
        return try subdirectories(of: root).first { FolderNaming.sameName($0.lastPathComponent, wanted) }
    }

    private func subjectFolderCreatingIfNeeded(_ rawName: String) throws -> URL {
        let name = try validName(rawName)
        if let existing = try existingSubjectFolder(named: name) { return existing }
        return try createSubject(named: name)
    }

    /// Имя папки точно (с учётом регистра) совпадает с базовым или с его вариантом с суффиксом ` (N)`.
    private func folderName(_ name: String, matchesBase base: String) -> Bool {
        let name = name.precomposedStringWithCanonicalMapping
        let base = base.precomposedStringWithCanonicalMapping
        if name == base { return true }
        guard name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) else { return false }
        let number = name[open.upperBound..<name.index(before: name.endIndex)]
        return Int(number) != nil && String(name[..<open.lowerBound]) == base
    }

    /// Перемещение с координацией. Переименование с изменением только регистра делается через временное имя.
    private func moveItem(from source: URL, to target: URL) throws {
        if FolderNaming.samePath(source, target) {
            let temp = source.deletingLastPathComponent().appendingPathComponent(".inkling-rename-\(UUID().uuidString)")
            try coordinatedMove(from: source, to: temp)
            try coordinatedMove(from: temp, to: target)
        } else {
            try coordinatedMove(from: source, to: target)
        }
    }

    private func coordinatedMove(from source: URL, to target: URL) throws {
        var coordinationError: NSError?
        var moveError: Error?
        NSFileCoordinator().coordinate(writingItemAt: source, options: .forMoving,
                                       writingItemAt: target, options: .forReplacing,
                                       error: &coordinationError) { from, to in
            do {
                try FileManager.default.moveItem(at: from, to: to)
            } catch {
                moveError = error
            }
        }
        if let error = coordinationError ?? moveError { throw error }
    }

    private func subdirectories(of folder: URL) throws -> [URL] {
        guard fileManager.fileExists(atPath: folder.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                   options: [.skipsHiddenFiles])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }
}
