import CoreImage
import Foundation
import Observation

/// Этап 1 конвейера (SPEC, раздел 4): каждая страница рукописи и каждый слайд-картинка отдельно превращаются в Markdown.
/// Очередь общая для всех лекций; одновременно идёт не больше `maxParallel` вызовов (ещё и маршрутизатор ограничивает).
@MainActor
@Observable
final class RecognitionCenter {
    enum PageState: Equatable {
        case queued
        case running(engine: EngineID, startedAt: Date)
        case failed(AIError)
    }

    /// Прогресс по лекции для полосы над источниками.
    struct Batch: Equatable {
        var total = 0
        var done = 0
        var failed = 0
        var startedAt = Date()
        var engine: EngineID?
        /// «Повтор…» или «Переход на запасной движок…».
        var note: String?
    }

    private struct Job: Equatable {
        var lectureID: UUID
        var pageID: String
        /// Режим «Подробно»: страница читается по перекрывающимся фрагментам, только через Claude.
        var detailed = false
    }

    private(set) var states: [String: PageState] = [:]
    private(set) var batches: [UUID: Batch] = [:]
    /// Последняя ошибка, из-за которой очередь остановлена (нет входа, лимит и т. п.).
    var blockingError: AIError?

    @ObservationIgnored private let library: Library
    @ObservationIgnored private let router: @MainActor () -> EngineRouter
    @ObservationIgnored private let timeout: @MainActor () -> TimeInterval
    @ObservationIgnored private let maxParallel: @MainActor () -> Int
    @ObservationIgnored private var queue: [Job] = []
    @ObservationIgnored private var workers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var running: [String: Task<Void, Never>] = [:]

    init(library: Library, router: @escaping @MainActor () -> EngineRouter,
         timeout: @escaping @MainActor () -> TimeInterval, maxParallel: @escaping @MainActor () -> Int) {
        self.library = library
        self.router = router
        self.timeout = timeout
        self.maxParallel = maxParallel
    }

    func state(of pageID: String) -> PageState? { states[pageID] }

    func isBusy(_ lectureID: UUID) -> Bool { batches[lectureID] != nil }

    // MARK: Очередь

    /// Ставит страницы в очередь; уже стоящие или идущие пропускаются.
    func recognize(lectureID: UUID, pageIDs: [String], detailed: Bool = false) {
        blockingError = nil
        var batch = batches[lectureID] ?? Batch()
        for id in pageIDs {
            if case .queued = states[id] { continue }
            if case .running = states[id] { continue }
            states[id] = .queued
            queue.append(Job(lectureID: lectureID, pageID: id, detailed: detailed))
            batch.total += 1
        }
        guard batch.total > batch.done + batch.failed else { return }
        batches[lectureID] = batch
        startWorkers()
    }

    /// Все страницы лекции без текста (и слайды-картинки, у которых текст только из текстового слоя).
    func pendingPages(in lecture: LectureRecord) -> [String] {
        lecture.meta.notes.filter { $0.text == nil }.map(\.id) + lecture.meta.slides.filter(\.needsRecognition).map(\.id)
    }

    /// «Отменить»: убирает из очереди страницы лекции и прерывает идущие вызовы.
    func cancel(lectureID: UUID) {
        let removed = queue.filter { $0.lectureID == lectureID }.map(\.pageID)
        queue.removeAll { $0.lectureID == lectureID }
        for id in removed { states[id] = nil }
        for (id, task) in running where jobsLecture[id] == lectureID { task.cancel() }
        batches[lectureID] = nil
    }

    /// Лекция каждой страницы, которая сейчас обрабатывается.
    @ObservationIgnored private var jobsLecture: [String: UUID] = [:]

    private func startWorkers() {
        let limit = max(1, maxParallel())
        while workers.count < limit, !queue.isEmpty {
            let workerID = UUID()
            workers[workerID] = Task { [weak self] in
                await self?.workLoop()
                self?.workers[workerID] = nil
            }
        }
    }

    private func workLoop() async {
        while !queue.isEmpty {
            let job = queue.removeFirst()
            jobsLecture[job.pageID] = job.lectureID
            let task = Task { await self.process(job) }
            running[job.pageID] = task
            await task.value
            running[job.pageID] = nil
            jobsLecture[job.pageID] = nil
            settle(job.lectureID)
        }
    }

    /// Закрывает прогресс лекции, когда у неё не осталось ни задач в очереди, ни идущих вызовов.
    private func settle(_ lectureID: UUID) {
        guard let batch = batches[lectureID],
              !queue.contains(where: { $0.lectureID == lectureID }),
              !jobsLecture.values.contains(lectureID) else { return }
        batches[lectureID] = nil
        if batch.failed > 0 { lastFailures[lectureID] = batch.failed }
    }

    // MARK: Одна страница

    private func process(_ job: Job) async {
        guard let lecture = library.lecture(id: job.lectureID) ?? (try? library.store.findLecture(id: job.lectureID, hint: library.lecture(id: job.lectureID)?.folder)) ?? nil,
              let location = lecture.meta.page(job.pageID) else {
            finish(job, failed: false)
            return
        }
        let paths = LecturePaths(folder: lecture.folder)
        let image = location.section == .notes ? paths.notePhoto(job.pageID) : paths.slideImage(job.pageID)
        let request: AIRequest
        var bandsFolder: URL?
        defer { if let bandsFolder { try? FileManager.default.removeItem(at: bandsFolder) } }
        do {
            guard FileManager.default.fileExists(atPath: image.path) else {
                throw AIError.invalidOutput("Нет картинки страницы: \(image.lastPathComponent)")
            }
            if job.detailed, location.section == .notes {
                let page = lecture.meta.notes[location.index]
                let original = paths.original(page.source, in: .notes)
                let folder = try await Self.writeBands(of: page, original: original)
                bandsFolder = folder
                let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.sorted() ?? []
                let prompt = try library.prompts.detailedRecognitionPrompt(subject: lecture.meta.subject, topic: lecture.meta.topic,
                                                                           imageNames: names)
                var detailedRequest = AIRequest(prompt: prompt, systemPrompt: PromptLibrary.recognitionSystemPrompt,
                                                images: names.map { folder.appendingPathComponent($0) }, format: .text,
                                                timeout: timeout() * 2)
                detailedRequest.requiredEngine = .claude
                request = detailedRequest
            } else {
                let prompt = try library.prompts.recognitionPrompt(section: location.section, subject: lecture.meta.subject,
                                                                   topic: lecture.meta.topic, imageName: image.lastPathComponent)
                request = AIRequest(prompt: prompt, systemPrompt: PromptLibrary.recognitionSystemPrompt, images: [image],
                                    format: .text, timeout: timeout())
            }
        } catch {
            fail(job, error as? AIError ?? .invalidOutput(error.localizedDescription))
            return
        }
        let imageHash = FileHash.sha256(image)

        let lectureID = job.lectureID
        states[job.pageID] = .running(engine: router().primaryID, startedAt: Date())
        let result: Result<AIResponse, AIError>
        do {
            result = .success(try await router().run(request) { event in
                Task { @MainActor in self.note(event, lectureID: lectureID, pageID: job.pageID) }
            })
        } catch {
            result = .failure(error)
        }

        switch result {
        case .success(let response):
            do {
                try save(response, job: job, imageHash: imageHash)
                finish(job, failed: false)
            } catch {
                fail(job, .invalidOutput("Не удалось сохранить текст: \(error.localizedDescription)"))
            }
        case .failure(.cancelled):
            states[job.pageID] = nil
        case .failure(let error):
            fail(job, error)
        }
    }

    /// Нарезает оригинал страницы на фрагменты для режима «Подробно» (вне главного потока) и пишет их во временную папку.
    nonisolated private static func writeBands(of page: NotePage, original: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let image: CIImage
            switch page.source {
            case .image: image = try ImageProcessor.loadOriented(original)
            case .pdfPage(_, let index): image = try PDFTools.renderPage(original, index: index)
            }
            let bands = try ImageProcessor.detailedBands(image, crop: page.crop, rotation: page.rotation)
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("Inkling-bands-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (index, data) in bands.enumerated() {
                try data.write(to: folder.appendingPathComponent("part\(index + 1).jpg"))
            }
            return folder
        }.value
    }

    /// Записывает текст страницы (прежний — в историю) и описание в `meta.json`. Папка ищется заново:
    /// лекцию могли переименовать, пока шёл запрос.
    private func save(_ response: AIResponse, job: Job, imageHash: String?) throws {
        guard let lecture = try library.store.findLecture(id: job.lectureID, hint: library.lecture(id: job.lectureID)?.folder),
              let location = lecture.meta.page(job.pageID) else { return }
        let previous = lecture.meta.pageText(job.pageID)
        // Локальная модель иногда заворачивает весь ответ в ```markdown — снимаем, как при сборке.
        let text = MarkdownCleanup.unwrap(response.text) + "\n"
        try PageTextStore(paths: LecturePaths(folder: lecture.folder))
            .write(text, id: job.pageID, in: location.section, previous: previous)
        let info = PageText(origin: .model, engine: response.engine, model: response.model,
                            updatedAt: JSONCoding.rounded(Date()), manuallyEdited: false, imageHash: imageHash)
        library.mutate(job.lectureID) { $0.setPageText(info, for: job.pageID) }
        library.pageRevisions[job.pageID, default: 0] += 1
    }

    private func note(_ event: EngineRouter.Event, lectureID: UUID, pageID: String) {
        guard var batch = batches[lectureID] else { return }
        switch event {
        case .started(let engine):
            batch.engine = engine
            if case .running(_, let startedAt) = states[pageID] { states[pageID] = .running(engine: engine, startedAt: startedAt) }
        case .retrying(_, let error):
            batch.note = "Повтор после ошибки: \(error.userMessage)"
        case .switchedToFallback(_, let to, let error):
            batch.engine = to
            batch.note = "\(error.userMessage) Переход на \(to.title)."
        }
        batches[lectureID] = batch
    }

    private func fail(_ job: Job, _ error: AIError) {
        states[job.pageID] = .failed(error)
        finish(job, failed: true)
        // Нет входа, нет бинарника, лимит без запасного: остальные страницы упадут так же — останавливаем очередь.
        switch error {
        case .notAuthenticated, .binaryNotFound, .rateLimited, .ollamaUnavailable, .modelNotInstalled:
            blockingError = error
            let stopped = queue
            queue.removeAll()
            for other in stopped {
                states[other.pageID] = .failed(error)
                batches[other.lectureID]?.failed += 1
            }
        case .processFailed where error.isModelUnavailable:
            blockingError = error
        default:
            break
        }
    }

    private func finish(_ job: Job, failed: Bool) {
        if !failed { states[job.pageID] = nil }
        guard var batch = batches[job.lectureID] else { return }
        if failed { batch.failed += 1 } else { batch.done += 1 }
        batch.note = nil
        batches[job.lectureID] = batch
    }

    /// Сколько страниц не распознано в последнем прогоне лекции (для подсказки после окончания).
    private(set) var lastFailures: [UUID: Int] = [:]

    func clearFailures(_ lectureID: UUID) { lastFailures[lectureID] = nil }
}
