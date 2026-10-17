import Foundation
import Observation

/// «Дополнить» (SPEC, раздел 13): отдельный проход поверх готового конспекта. Модель добавляет резюме, пояснения,
/// примеры, графики и схемы помеченными блоками и выделяет термины; текст автора не меняется (проверяется кодом).
/// Затем второй вызов ищет ошибки в добавленном, найденные блоки вырезаются. Работает только через Claude.
@MainActor
@Observable
final class EnrichmentCenter {
    enum Stage: Equatable {
        case enriching
        case verifying
    }

    struct Run: Equatable {
        var stage = Stage.enriching
        var startedAt = Date()
        var engine: EngineID?
        var note: String?
    }

    private(set) var runs: [UUID: Run] = [:]
    var errors: [UUID: AIError] = [:]

    @ObservationIgnored private let library: Library
    @ObservationIgnored private let router: @MainActor () -> EngineRouter
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    init(library: Library, router: @escaping @MainActor () -> EngineRouter) {
        self.library = library
        self.router = router
    }

    func isRunning(_ lectureID: UUID) -> Bool { runs[lectureID] != nil }

    func cancel(_ lectureID: UUID) { tasks[lectureID]?.cancel() }

    static let systemPrompt = """
    Ты помогаешь студенту учить конспект. Изображений нет, инструменты не нужны. \
    Слова автора конспекта не меняй: только добавляй помеченные блоки и выделяй термины.
    """

    static let verifySystemPrompt = """
    Ты строгий проверяющий. Изображений нет, инструменты не нужны. \
    Ответ — строго один JSON-объект по заданной схеме.
    """

    func enrich(_ lectureID: UUID) {
        guard runs[lectureID] == nil, let lecture = library.lecture(id: lectureID) else { return }
        errors[lectureID] = nil
        let current = KonspektStore(folder: lecture.folder).read() ?? ""
        let base = Enrichment.removing(from: current).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else {
            errors[lectureID] = .invalidOutput("Сначала соберите конспект: дополнять нечего.")
            return
        }
        let prompts = library.prompts
        let subject = lecture.meta.subject, topic = lecture.meta.topic
        let router = router()
        runs[lectureID] = Run()

        tasks[lectureID] = Task {
            defer {
                runs[lectureID] = nil
                tasks[lectureID] = nil
            }
            do {
                let result = try await run(base: base, subject: subject, topic: topic, prompts: prompts, router: router,
                                           lectureID: lectureID)
                try save(result, readAtStart: current, lectureID: lectureID)
            } catch let error as AIError {
                if error != .cancelled { errors[lectureID] = error }
            } catch {
                errors[lectureID] = .invalidOutput(error.localizedDescription)
            }
        }
    }

    struct Result {
        var text: String
        var response: AIResponse
        var added: Int
        var removed: Int
    }

    private func run(base: String, subject: String, topic: String, prompts: PromptLibrary, router: EngineRouter,
                     lectureID: UUID) async throws -> Result {
        let onEvent: @Sendable (EngineRouter.Event) -> Void = { event in
            Task { @MainActor in self.note(event, lectureID: lectureID) }
        }
        let insert = prompts.subjectInsert(subject)
        let timeout = AssemblyPlanner.timeout(chars: base.count * 2)

        // 1. Дополнение. Если модель тронула слова автора, одна повторная попытка.
        let prompt = PromptLibrary.render(try prompts.template("enrich.md"), values: [
            "предмет": subject, "тема": topic, "вставка_предмета": insert, "конспект": base,
        ])
        var enriched: String?
        var response: AIResponse?
        for attempt in 0..<2 {
            var request = AIRequest(prompt: prompt, systemPrompt: Self.systemPrompt, format: .text, timeout: timeout)
            request.cloudOnly = true
            let answer = try await router.run(request, onEvent: onEvent)
            let text = MarkdownCleanup.unwrap(answer.text)
            if Enrichment.preservesAuthorText(original: base, enriched: text) {
                enriched = text
                response = answer
                break
            }
            if attempt == 0 { runs[lectureID]?.note = "Модель изменила текст автора, повторяю запрос" }
        }
        guard var text = enriched, let response else {
            throw AIError.invalidOutput("Модель изменила текст конспекта, дополнение не сохранено. Попробуйте ещё раз.")
        }
        if Task.isCancelled { throw AIError.cancelled }

        // 2. Проверка добавленного. Без неё ничего не сохраняется: блоки нельзя считать надёжными.
        let additions = Enrichment.additions(in: text)
        var removed = 0
        if !additions.isEmpty {
            runs[lectureID]?.stage = .verifying
            runs[lectureID]?.note = nil
            let verifyPrompt = PromptLibrary.render(try prompts.template("enrich-verify.md"), values: [
                "предмет": subject, "тема": topic, "конспект": base, "добавления": Enrichment.numberedList(additions),
            ])
            var request = AIRequest(prompt: verifyPrompt, systemPrompt: Self.verifySystemPrompt,
                                    format: .json(schema: Enrichment.verificationSchema), timeout: timeout)
            request.cloudOnly = true
            let verdict = try await router.run(request, onEvent: onEvent)
            guard let problems = Enrichment.parseProblems(verdict.json ?? Data(verdict.text.utf8), count: additions.count) else {
                throw AIError.invalidOutput("Не удалось разобрать ответ проверки, дополнение не сохранено.")
            }
            let bad = Set(problems.map { $0.id - 1 })
            removed = bad.count
            if !bad.isEmpty { text = Enrichment.removing(bad, from: text) }
        }
        return Result(text: text, response: response, added: additions.count - removed, removed: removed)
    }

    private func save(_ result: Result, readAtStart: String, lectureID: UUID) throws {
        guard let lecture = try library.store.findLecture(id: lectureID, hint: library.lecture(id: lectureID)?.folder) else {
            throw LibraryError.lectureNotFound
        }
        let store = KonspektStore(folder: lecture.folder)
        // Конспект могли пересобрать или поправить, пока шёл запрос: чужие изменения не затираем.
        guard store.read() == readAtStart else {
            throw AIError.invalidOutput("Конспект изменился во время дополнения. Запустите «Дополнить» ещё раз.")
        }
        guard Enrichment.preservesAuthorText(original: readAtStart, enriched: result.text) else {
            throw AIError.invalidOutput("Дополнение не сохранено: после проверки текст автора не совпадает с исходным.")
        }
        let now = JSONCoding.rounded(Date())
        try store.write(result.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n", previous: lecture.meta.konspekt)
        let enrichment = EnrichmentInfo(createdAt: now, engine: result.response.engine, model: result.response.model,
                                        added: result.added, removedByCheck: result.removed)
        library.mutate(lectureID) { meta in
            if var info = meta.konspekt {
                info.enrichment = enrichment
                info.updatedAt = now
                meta.konspekt = info
            }
        }
        library.konspektRevision[lectureID, default: 0] += 1
    }

    private func note(_ event: EngineRouter.Event, lectureID: UUID) {
        guard runs[lectureID] != nil else { return }
        switch event {
        case .started(let engine): runs[lectureID]?.engine = engine
        case .retrying(_, let error): runs[lectureID]?.note = "Повтор после ошибки: \(error.userMessage)"
        case .switchedToFallback: break
        }
    }
}
