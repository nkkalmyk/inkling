import Foundation
import Observation

/// Этап 3 конвейера (SPEC, разделы 4 и 5): учебные материалы по `konspekt.md`. Ответ строго в JSON по схеме;
/// при невалидном ответе — одна повторная попытка с текстом ошибок проверки.
@MainActor
@Observable
final class StudyCenter {
    struct Run: Equatable {
        var startedAt = Date()
        var engine: EngineID?
        var note: String?
    }

    private(set) var runs: [UUID: Run] = [:]
    var errors: [UUID: AIError] = [:]
    /// Растёт при перезаписи файлов, чтобы вкладки перечитали материалы и прогресс.
    private(set) var revisions: [UUID: Int] = [:]

    @ObservationIgnored private let library: Library
    @ObservationIgnored private let router: @MainActor () -> EngineRouter
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    private var konspektHashes: [UUID: String?] = [:]
    @ObservationIgnored private var hashKeys: [UUID: HashKey] = [:]
    @ObservationIgnored private var hashTasks: [UUID: Task<Void, Never>] = [:]

    init(library: Library, router: @escaping @MainActor () -> EngineRouter) {
        self.library = library
        self.router = router
    }

    func isRunning(_ lectureID: UUID) -> Bool { runs[lectureID] != nil }

    func revision(_ lectureID: UUID) -> Int { revisions[lectureID] ?? 0 }

    func store(_ lecture: LectureRecord) -> StudyStore { StudyStore(folder: lecture.folder) }

    /// Хеш текущего конспекта — входные данные учебных материалов.
    static func inputHash(_ lecture: LectureRecord) -> String? {
        KonspektStore(folder: lecture.folder).read().map { FileHash.sha256(Enrichment.baseText($0, info: lecture.meta.konspekt)) }
    }

    /// Конспект изменился после подготовки материалов. Читает конспект: для действий и тестов, не для `body`.
    func isStale(_ lecture: LectureRecord) -> Bool {
        guard let info = lecture.meta.study, let hash = Self.inputHash(lecture) else { return false }
        return info.inputHash != hash
    }

    /// То же для экранов: хеш конспекта из кэша, пересчёт в фоне при его изменении. Конспект лежит в iCloud Drive
    /// и может быть выгружен из Mac — чтение на главном потоке ждало бы загрузки. Пока хеш не готов — `false`.
    func knownStale(_ lecture: LectureRecord) -> Bool {
        guard let info = lecture.meta.study else { return false }
        let key = HashKey(konspekt: lecture.meta.konspekt, revision: library.konspektRevision[lecture.id] ?? 0)
        if hashKeys[lecture.id] != key { refreshHash(lecture, key: key) }
        guard let hash = konspektHashes[lecture.id] ?? nil else { return false }
        return info.inputHash != hash
    }

    private struct HashKey: Equatable {
        var konspekt: ArtifactInfo?
        var revision: Int
    }

    private func refreshHash(_ lecture: LectureRecord, key: HashKey) {
        let id = lecture.id, folder = lecture.folder, info = lecture.meta.konspekt
        hashKeys[id] = key
        hashTasks[id]?.cancel()
        hashTasks[id] = Task {
            let hash = await Self.konspektHash(folder: folder, info: info)
            guard !Task.isCancelled else { return }
            konspektHashes[id] = .some(hash)
        }
    }

    @concurrent
    private static func konspektHash(folder: URL, info: ArtifactInfo?) async -> String? {
        KonspektStore(folder: folder).read().map { FileHash.sha256(Enrichment.baseText($0, info: info)) }
    }

    func cancel(_ lectureID: UUID) { tasks[lectureID]?.cancel() }

    // MARK: Генерация

    func generate(_ lectureID: UUID) {
        guard runs[lectureID] == nil, let lecture = library.lecture(id: lectureID) else { return }
        errors[lectureID] = nil
        // Учебные материалы строятся по авторскому тексту: блоки кнопки «Дополнить» в них и в хеш не входят.
        let raw = Enrichment.baseText(KonspektStore(folder: lecture.folder).read() ?? "", info: lecture.meta.konspekt)
        let konspekt = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !konspekt.isEmpty else {
            errors[lectureID] = .invalidOutput("Сначала соберите конспект: материалы готовятся только по нему.")
            return
        }
        let prompt: String
        do {
            let prompts = library.prompts
            prompt = PromptLibrary.render(try prompts.template("study.md"), values: [
                "предмет": lecture.meta.subject, "тема": lecture.meta.topic,
                "вставка_предмета": prompts.subjectInsert(lecture.meta.subject), "конспект": konspekt,
            ])
        } catch {
            errors[lectureID] = .invalidOutput(error.localizedDescription)
            return
        }
        let router = router()
        let hash = FileHash.sha256(raw)
        runs[lectureID] = Run()
        tasks[lectureID] = Task {
            defer {
                runs[lectureID] = nil
                tasks[lectureID] = nil
            }
            do {
                let (study, response) = try await request(prompt: prompt, konspektChars: konspekt.count, router: router,
                                                          lectureID: lectureID)
                try save(study, response: response, inputHash: hash, lectureID: lectureID)
            } catch let error as AIError {
                if error != .cancelled { errors[lectureID] = error }
            } catch {
                errors[lectureID] = .invalidOutput(error.localizedDescription)
            }
        }
    }

    private func request(prompt: String, konspektChars: Int, router: EngineRouter,
                         lectureID: UUID) async throws(AIError) -> (StudyMaterials, AIResponse) {
        let onEvent: @Sendable (EngineRouter.Event) -> Void = { event in
            Task { @MainActor in self.note(event, lectureID: lectureID) }
        }
        let timeout = AssemblyPlanner.timeout(chars: konspektChars * 2)
        var current = AIRequest(prompt: prompt, systemPrompt: Self.systemPrompt,
                                format: .json(schema: StudyMaterials.jsonSchema), timeout: timeout)
        var lastProblems = ""
        for attempt in 0..<2 {
            let response = try await router.run(current, onEvent: onEvent)
            switch StudyMaterials.parse(response.json ?? Data(response.text.utf8)) {
            case .success(let study):
                return (study, response)
            case .failure(let error):
                lastProblems = error.message
                guard attempt == 0 else { break }
                runs[lectureID]?.note = "Ответ не прошёл проверку, повторяю запрос"
                current.prompt = prompt + "\n\nПредыдущий ответ не прошёл проверку:\n" + error.message
                    + "\nИсправь эти ошибки и верни JSON заново целиком."
            }
        }
        throw .invalidOutput("Учебные материалы не прошли проверку:\n" + lastProblems)
    }

    static let systemPrompt = """
    Ты готовишь учебные материалы по конспекту лекции. Изображений нет, инструменты не нужны. \
    Ответ — строго один JSON-объект по заданной схеме.
    """

    private func save(_ study: StudyMaterials, response: AIResponse, inputHash: String, lectureID: UUID) throws {
        guard let lecture = try library.store.findLecture(id: lectureID, hint: library.lecture(id: lectureID)?.folder) else { throw LibraryError.lectureNotFound }
        let now = JSONCoding.rounded(Date())
        try StudyStore(folder: lecture.folder).writeNew(study, previous: lecture.meta.study)
        let info = ArtifactInfo(engine: response.engine, model: response.model, createdAt: now, updatedAt: now,
                                inputHash: inputHash)
        library.mutate(lectureID) { $0.study = info }
        revisions[lectureID, default: 0] += 1
    }

    private func note(_ event: EngineRouter.Event, lectureID: UUID) {
        guard runs[lectureID] != nil else { return }
        switch event {
        case .started(let engine): runs[lectureID]?.engine = engine
        case .retrying(_, let error): runs[lectureID]?.note = "Повтор после ошибки: \(error.userMessage)"
        case .switchedToFallback(_, let to, let error):
            runs[lectureID]?.engine = to
            runs[lectureID]?.note = "\(error.userMessage) Переход на \(to.title)."
        }
    }

    // MARK: Правка и прогресс

    /// Ручная правка материалов; при первой правке результат модели уходит в историю, прогресс сохраняется.
    func saveEdited(_ study: StudyMaterials, lectureID: UUID) {
        guard let lecture = library.lecture(id: lectureID) else { return }
        let info = lecture.meta.study
        do {
            try StudyStore(folder: lecture.folder).writeEdited(study, previous: info, saveHistory: info?.manuallyEdited != true)
        } catch {
            library.errorMessage = "Не удалось сохранить материалы: \(error.localizedDescription)"
            return
        }
        if var info, !info.manuallyEdited {
            info.manuallyEdited = true
            info.updatedAt = JSONCoding.rounded(Date())
            library.mutate(lectureID) { $0.study = info }
        }
        revisions[lectureID, default: 0] += 1
    }

    func updateProgress(_ lectureID: UUID, _ change: (inout StudyProgress) -> Void) {
        guard let lecture = library.lecture(id: lectureID) else { return }
        let store = StudyStore(folder: lecture.folder)
        var progress = store.readProgress()
        change(&progress)
        do {
            try store.writeProgress(progress)
        } catch {
            library.errorMessage = "Не удалось сохранить прогресс: \(error.localizedDescription)"
        }
        revisions[lectureID, default: 0] += 1
    }
}
