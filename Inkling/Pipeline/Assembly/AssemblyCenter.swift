import Foundation
import Observation

/// Этап 2 конвейера (SPEC, раздел 4): сборка конспекта по кнопке. Части длинной лекции идут параллельно
/// (маршрутизатор ограничивает число вызовов), затем финальный проход склейки.
@MainActor
@Observable
final class AssemblyCenter {
    struct Run: Equatable {
        var totalCalls: Int
        var finishedCalls = 0
        var merging = false
        var startedAt = Date()
        var engine: EngineID?
        var note: String?
    }

    /// Состояние кнопки «Собрать» для лекции.
    struct Readiness: Equatable {
        var input: AssemblyInput
        var plan: AssemblyPlan?
        /// Конспект собран из других текстов страниц или в другом порядке.
        var isStale: Bool
    }

    private(set) var runs: [UUID: Run] = [:]
    var errors: [UUID: AIError] = [:]
    /// Вызывается после успешной сборки (для «запускать учебные материалы автоматически»).
    @ObservationIgnored var onAssembled: ((UUID) -> Void)?

    @ObservationIgnored private let library: Library
    @ObservationIgnored private let router: @MainActor () -> EngineRouter
    @ObservationIgnored private let threshold: @MainActor () -> Int
    /// Стиль по умолчанию и модель Claude для сборки (из настроек). В тестах — точная сборка без выбора модели.
    @ObservationIgnored private let defaultStyle: @MainActor () -> AssemblyStyle
    @ObservationIgnored private let assemblyModel: @MainActor () -> String
    /// Выдержки из учебников для предмета и темы (по словам лекции); в тестах — пусто.
    @ObservationIgnored private let literature: @MainActor (_ subject: String, _ topic: String, _ texts: [String]) async -> [LiteraturePassage]
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    private var cachedReadiness: [UUID: Readiness] = [:]
    @ObservationIgnored private var readinessKeys: [UUID: ReadinessKey] = [:]
    @ObservationIgnored private var readinessTasks: [UUID: Task<Void, Never>] = [:]

    init(library: Library, router: @escaping @MainActor () -> EngineRouter, threshold: @escaping @MainActor () -> Int,
         style: @escaping @MainActor () -> AssemblyStyle = { .faithful },
         model: @escaping @MainActor () -> String = { "" },
         literature: @escaping @MainActor (String, String, [String]) async -> [LiteraturePassage] = { _, _, _ in [] }) {
        self.library = library
        self.router = router
        self.threshold = threshold
        defaultStyle = style
        assemblyModel = model
        self.literature = literature
    }

    func isRunning(_ lectureID: UUID) -> Bool { runs[lectureID] != nil }

    /// Готовность к сборке для экранов: из кэша, без чтения диска на главном потоке. Тексты страниц лежат
    /// в iCloud Drive и могут быть выгружены из Mac — чтение тогда ждёт загрузки, и окно зависало на десятки секунд.
    /// Если лекция или тексты изменились, пересчёт идёт в фоне, а до его конца возвращается прежний результат
    /// (`nil`, пока его ещё не было).
    func knownReadiness(_ lecture: LectureRecord) -> Readiness? {
        let key = ReadinessKey(meta: lecture.meta, texts: library.textRevision[lecture.id] ?? 0, threshold: threshold())
        if readinessKeys[lecture.id] != key { refreshReadiness(lecture, key: key) }
        return cachedReadiness[lecture.id]
    }

    /// Готовность сейчас, с чтением текстов. Для действий пользователя (собрать, подтвердить) и тестов, не для `body`.
    func readiness(_ lecture: LectureRecord) -> Readiness {
        Self.readiness(meta: lecture.meta, input: Self.collect(meta: lecture.meta, paths: LecturePaths(folder: lecture.folder)),
                       threshold: threshold())
    }

    private struct ReadinessKey: Equatable {
        var meta: LectureMeta
        var texts: Int
        var threshold: Int
    }

    private func refreshReadiness(_ lecture: LectureRecord, key: ReadinessKey) {
        let id = lecture.id, meta = lecture.meta, paths = LecturePaths(folder: lecture.folder)
        readinessKeys[id] = key
        readinessTasks[id]?.cancel()
        readinessTasks[id] = Task {
            let input = await Self.collectInBackground(meta: meta, paths: paths)
            guard !Task.isCancelled else { return }
            cachedReadiness[id] = Self.readiness(meta: meta, input: input, threshold: key.threshold)
        }
    }

    @concurrent
    private static func collectInBackground(meta: LectureMeta, paths: LecturePaths) async -> AssemblyInput {
        collect(meta: meta, paths: paths)
    }

    nonisolated private static func collect(meta: LectureMeta, paths: LecturePaths) -> AssemblyInput {
        AssemblyInput.collect(meta: meta, texts: PageTextStore(paths: paths))
    }

    nonisolated private static func readiness(meta: LectureMeta, input: AssemblyInput, threshold: Int) -> Readiness {
        let stale = meta.konspekt.map { $0.inputHash != input.hash } ?? false
        return Readiness(input: input, plan: AssemblyPlanner.plan(input, threshold: threshold), isStale: stale)
    }

    func cancel(_ lectureID: UUID) {
        tasks[lectureID]?.cancel()
    }

    // MARK: Сборка

    /// `style` — `nil` берёт стиль из настроек.
    func assemble(_ lectureID: UUID, style: AssemblyStyle? = nil) {
        guard runs[lectureID] == nil, let lecture = library.lecture(id: lectureID) else { return }
        errors[lectureID] = nil
        let paths = LecturePaths(folder: lecture.folder)
        let input = AssemblyInput.collect(meta: lecture.meta, texts: PageTextStore(paths: paths))
        guard let plan = AssemblyPlanner.plan(input, threshold: threshold()) else {
            errors[lectureID] = .invalidOutput("Нет распознанных страниц: собирать не из чего.")
            return
        }
        let router = router()
        // Локальная модель с десятком фотографий не справляется: при «Только локальная» остаётся точная сборка.
        let style = router.primaryID.isCloud ? (style ?? defaultStyle()) : .faithful
        let studyPlan = style == .study
            ? StudyAssemblyPlanner.plan(meta: lecture.meta, input: input, paths: paths, textThreshold: threshold()) : nil
        let subject = lecture.meta.subject, topic = lecture.meta.topic
        let prompts = library.prompts
        let model = assemblyModel().trimmingCharacters(in: .whitespaces)
        runs[lectureID] = Run(totalCalls: studyPlan?.calls ?? plan.calls)

        tasks[lectureID] = Task {
            defer {
                runs[lectureID] = nil
                tasks[lectureID] = nil
            }
            do {
                let result: (text: String, response: AIResponse)
                var passages: [LiteraturePassage] = []
                if let studyPlan {
                    passages = await literature(subject, topic, input.notes.map(\.text) + input.slides.map(\.text))
                    result = try await runStudy(studyPlan, subject: subject, topic: topic, prompts: prompts, router: router,
                                                model: model, textbooks: LiteratureRetrieval.promptBlock(passages), lectureID: lectureID)
                } else {
                    result = try await run(plan, input: input, subject: subject, topic: topic, prompts: prompts,
                                           router: router, lectureID: lectureID)
                }
                try save(result.text, response: result.response, plan: plan, input: input,
                         style: studyPlan == nil ? .faithful : .study, parts: studyPlan?.parts.count ?? plan.parts.count,
                         literature: passages.isEmpty ? nil : LiteratureRetrieval.references(passages), lectureID: lectureID)
            } catch let error as AIError {
                if error != .cancelled { errors[lectureID] = error }
            } catch {
                errors[lectureID] = .invalidOutput(error.localizedDescription)
            }
        }
    }

    /// Учебная сборка: фото страниц уходят модели целиком (только облачный движок), части идут параллельно, затем склейка.
    private func runStudy(_ plan: StudyPlan, subject: String, topic: String, prompts: PromptLibrary, router: EngineRouter,
                          model: String, textbooks: String, lectureID: UUID) async throws -> (text: String, response: AIResponse) {
        let requests = try plan.parts.enumerated().map { index, part -> AIRequest in
            var request = AIRequest(
                prompt: try prompts.studyAssemblyPrompt(part: part, index: index, of: plan.parts.count, subject: subject, topic: topic,
                                                   textbooks: textbooks),
                systemPrompt: PromptLibrary.studyAssemblySystemPrompt, images: part.notes.map(\.image), format: .text,
                timeout: StudyAssemblyPlanner.timeout(images: part.notes.count,
                                                      chars: (part.notes.map(\.draft.count) + part.slides.map(\.text.count)).reduce(0, +)))
            request.cloudOnly = true
            if !model.isEmpty {
                request.model = model
                request.modelEngine = .claude
            }
            return request
        }
        let responses = try await runRequests(requests, lectureID: lectureID, router: router)
        guard plan.needsMerge else { return (MarkdownCleanup.unwrap(responses[0].text), responses[0]) }
        return try await merge(responses.map { MarkdownCleanup.unwrap($0.text) }, subject: subject, topic: topic, prompts: prompts,
                               router: router, model: model, cloud: true, lectureID: lectureID)
    }

    private func run(_ plan: AssemblyPlan, input: AssemblyInput, subject: String, topic: String, prompts: PromptLibrary,
                     router: EngineRouter, lectureID: UUID) async throws -> (text: String, response: AIResponse) {
        let requests = try plan.parts.enumerated().map { index, part in
            AIRequest(prompt: try prompts.assemblyPrompt(mode: plan.mode, part: part, index: index, of: plan.parts.count,
                                                         subject: subject, topic: topic),
                      systemPrompt: PromptLibrary.assemblySystemPrompt, format: .text,
                      timeout: AssemblyPlanner.timeout(chars: (part.notes + part.slides).reduce(0) { $0 + $1.text.count }))
        }

        let responses = try await runRequests(requests, lectureID: lectureID, router: router)
        guard plan.needsMerge else {
            return (MarkdownCleanup.unwrap(responses[0].text), responses[0])
        }
        return try await merge(responses.map { MarkdownCleanup.unwrap($0.text) }, subject: subject, topic: topic, prompts: prompts,
                               router: router, model: "", cloud: false, lectureID: lectureID)
    }

    /// Запросы частей идут параллельно (маршрутизатор ограничивает число вызовов); ответы — в порядке запросов.
    private func runRequests(_ requests: [AIRequest], lectureID: UUID, router: EngineRouter) async throws -> [AIResponse] {
        let onEvent: @Sendable (EngineRouter.Event) -> Void = { event in
            Task { @MainActor in self.note(event, lectureID: lectureID) }
        }
        var outputs = [AIResponse?](repeating: nil, count: requests.count)
        try await withThrowingTaskGroup(of: (Int, AIResponse).self) { group in
            for (index, request) in requests.enumerated() {
                group.addTask { (index, try await router.run(request, onEvent: onEvent)) }
            }
            for try await (index, response) in group {
                outputs[index] = response
                runs[lectureID]?.finishedCalls += 1
            }
        }
        if Task.isCancelled { throw AIError.cancelled }
        return outputs.compactMap { $0 }
    }

    /// Финальный проход: склейка частей длинной лекции.
    private func merge(_ parts: [String], subject: String, topic: String, prompts: PromptLibrary, router: EngineRouter,
                       model: String, cloud: Bool, lectureID: UUID) async throws -> (text: String, response: AIResponse) {
        runs[lectureID]?.merging = true
        let onEvent: @Sendable (EngineRouter.Event) -> Void = { event in
            Task { @MainActor in self.note(event, lectureID: lectureID) }
        }
        let mergeText = try prompts.mergePrompt(parts: parts, subject: subject, topic: topic, study: cloud)
        var request = AIRequest(prompt: mergeText, systemPrompt: PromptLibrary.assemblySystemPrompt, format: .text,
                                timeout: AssemblyPlanner.timeout(chars: mergeText.count))
        request.cloudOnly = cloud
        if !model.isEmpty {
            request.model = model
            request.modelEngine = .claude
        }
        let merged = try await router.run(request, onEvent: onEvent)
        runs[lectureID]?.finishedCalls += 1
        return (MarkdownCleanup.unwrap(merged.text), merged)
    }

    /// Пишет `konspekt.md` (прежний — в историю) и описание в `meta.json`. Папка ищется заново.
    private func save(_ text: String, response: AIResponse, plan: AssemblyPlan, input: AssemblyInput, style: AssemblyStyle,
                      parts: Int, literature: [String]?, lectureID: UUID) throws {
        guard !text.isEmpty else { throw AIError.invalidOutput("Модель вернула пустой конспект.") }
        guard let lecture = try library.store.findLecture(id: lectureID, hint: library.lecture(id: lectureID)?.folder) else { throw LibraryError.lectureNotFound }
        let now = JSONCoding.rounded(Date())
        try KonspektStore(folder: lecture.folder).write(text + "\n", previous: lecture.meta.konspekt)
        let info = ArtifactInfo(engine: response.engine, model: response.model, createdAt: now, updatedAt: now,
                                manuallyEdited: false, inputHash: input.hash, mode: plan.mode, parts: parts,
                                skippedPages: input.unrecognizedNotes + input.unrecognizedSlides)
        var stamped = info
        stamped.style = style
        stamped.literature = literature
        library.mutate(lectureID) { $0.konspekt = stamped }
        library.konspektRevision[lectureID, default: 0] += 1
        onAssembled?(lectureID)
    }

    private func note(_ event: EngineRouter.Event, lectureID: UUID) {
        guard runs[lectureID] != nil else { return }
        switch event {
        case .started(let engine):
            runs[lectureID]?.engine = engine
        case .retrying(_, let error):
            runs[lectureID]?.note = "Повтор после ошибки: \(error.userMessage)"
        case .switchedToFallback(_, let to, let error):
            runs[lectureID]?.engine = to
            runs[lectureID]?.note = "\(error.userMessage) Переход на \(to.title)."
        }
    }
}

extension Library {
    /// Сохраняет ручную правку конспекта. При первой правке результата модели прежняя версия уходит в историю.
    func saveKonspektEdit(_ text: String, lectureID: UUID) {
        guard let lecture = lecture(id: lectureID) else { return }
        let store = KonspektStore(folder: lecture.folder)
        guard store.read() != text else { return }
        let current = lecture.meta.konspekt
        do {
            try store.write(text, previous: current, saveHistory: current?.manuallyEdited != true)
        } catch {
            errorMessage = "Не удалось сохранить конспект: \(error.localizedDescription)"
            return
        }
        if var info = current, !info.manuallyEdited {
            info.manuallyEdited = true
            info.updatedAt = JSONCoding.rounded(Date())
            mutate(lectureID) { $0.konspekt = info }
        } else if current == nil {
            let now = JSONCoding.rounded(Date())
            let input = AssemblyInput.collect(meta: lecture.meta, texts: PageTextStore(paths: LecturePaths(folder: lecture.folder)))
            mutate(lectureID) {
                $0.konspekt = ArtifactInfo(createdAt: now, updatedAt: now, manuallyEdited: true, inputHash: input.hash)
            }
        }
    }

    func restoreKonspekt(_ entry: HistoryStore.Entry, lectureID: UUID) {
        guard let lecture = lecture(id: lectureID) else { return }
        do {
            let restored = try KonspektStore(folder: lecture.folder).restore(entry, current: lecture.meta.konspekt)
            if var info = restored ?? lecture.meta.konspekt {
                info.updatedAt = JSONCoding.rounded(Date())
                if restored == nil { info.manuallyEdited = true }
                mutate(lectureID) { $0.konspekt = info }
            }
            konspektRevision[lectureID, default: 0] += 1
        } catch {
            errorMessage = "Не удалось восстановить версию: \(error.localizedDescription)"
        }
    }
}
