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
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    init(library: Library, router: @escaping @MainActor () -> EngineRouter, threshold: @escaping @MainActor () -> Int) {
        self.library = library
        self.router = router
        self.threshold = threshold
    }

    func isRunning(_ lectureID: UUID) -> Bool { runs[lectureID] != nil }

    func readiness(_ lecture: LectureRecord) -> Readiness {
        let input = AssemblyInput.collect(meta: lecture.meta, texts: PageTextStore(paths: LecturePaths(folder: lecture.folder)))
        let stale = lecture.meta.konspekt.map { $0.inputHash != input.hash } ?? false
        return Readiness(input: input, plan: AssemblyPlanner.plan(input, threshold: threshold()), isStale: stale)
    }

    func cancel(_ lectureID: UUID) {
        tasks[lectureID]?.cancel()
    }

    // MARK: Сборка

    func assemble(_ lectureID: UUID) {
        guard runs[lectureID] == nil, let lecture = library.lecture(id: lectureID) else { return }
        errors[lectureID] = nil
        let input = AssemblyInput.collect(meta: lecture.meta, texts: PageTextStore(paths: LecturePaths(folder: lecture.folder)))
        guard let plan = AssemblyPlanner.plan(input, threshold: threshold()) else {
            errors[lectureID] = .invalidOutput("Нет распознанных страниц: собирать не из чего.")
            return
        }
        let subject = lecture.meta.subject, topic = lecture.meta.topic
        let prompts = library.prompts
        let router = router()
        runs[lectureID] = Run(totalCalls: plan.calls)

        tasks[lectureID] = Task {
            defer {
                runs[lectureID] = nil
                tasks[lectureID] = nil
            }
            do {
                let result = try await run(plan, input: input, subject: subject, topic: topic, prompts: prompts,
                                           router: router, lectureID: lectureID)
                try save(result.text, response: result.response, plan: plan, input: input, lectureID: lectureID)
            } catch let error as AIError {
                if error != .cancelled { errors[lectureID] = error }
            } catch {
                errors[lectureID] = .invalidOutput(error.localizedDescription)
            }
        }
    }

    private func run(_ plan: AssemblyPlan, input: AssemblyInput, subject: String, topic: String, prompts: PromptLibrary,
                     router: EngineRouter, lectureID: UUID) async throws -> (text: String, response: AIResponse) {
        let requests = try plan.parts.enumerated().map { index, part in
            AIRequest(prompt: try prompts.assemblyPrompt(mode: plan.mode, part: part, index: index, of: plan.parts.count,
                                                         subject: subject, topic: topic),
                      systemPrompt: PromptLibrary.assemblySystemPrompt, format: .text,
                      timeout: AssemblyPlanner.timeout(chars: (part.notes + part.slides).reduce(0) { $0 + $1.text.count }))
        }

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
        let responses = outputs.compactMap { $0 }
        if Task.isCancelled { throw AIError.cancelled }
        guard plan.needsMerge else {
            return (MarkdownCleanup.unwrap(responses[0].text), responses[0])
        }

        runs[lectureID]?.merging = true
        let parts = responses.map { MarkdownCleanup.unwrap($0.text) }
        let mergeText = try prompts.mergePrompt(parts: parts, subject: subject, topic: topic)
        let merged = try await router.run(AIRequest(prompt: mergeText, systemPrompt: PromptLibrary.assemblySystemPrompt,
                                                    format: .text, timeout: AssemblyPlanner.timeout(chars: mergeText.count)),
                                          onEvent: onEvent)
        runs[lectureID]?.finishedCalls += 1
        return (MarkdownCleanup.unwrap(merged.text), merged)
    }

    /// Пишет `konspekt.md` (прежний — в историю) и описание в `meta.json`. Папка ищется заново.
    private func save(_ text: String, response: AIResponse, plan: AssemblyPlan, input: AssemblyInput, lectureID: UUID) throws {
        guard !text.isEmpty else { throw AIError.invalidOutput("Модель вернула пустой конспект.") }
        guard let lecture = try library.store.findLecture(id: lectureID, hint: library.lecture(id: lectureID)?.folder) else { throw LibraryError.lectureNotFound }
        let now = JSONCoding.rounded(Date())
        try KonspektStore(folder: lecture.folder).write(text + "\n", previous: lecture.meta.konspekt)
        let info = ArtifactInfo(engine: response.engine, model: response.model, createdAt: now, updatedAt: now,
                                manuallyEdited: false, inputHash: input.hash, mode: plan.mode, parts: plan.parts.count,
                                skippedPages: input.unrecognizedNotes + input.unrecognizedSlides)
        library.mutate(lectureID) { $0.konspekt = info }
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
