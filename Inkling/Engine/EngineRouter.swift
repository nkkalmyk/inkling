import Foundation

/// Общее для всех маршрутизаторов приложения: ограничение одновременных вызовов и пометки «лимит до …».
/// Маршрутизатор пересоздаётся при смене настроек (меню «Модель»), а вызовы старого продолжаются: со своим счётчиком
/// у каждого одновременно шло бы до вдвое больше вызовов, а пометки лимита сбрасывались бы (аудит 2026-11).
actor EngineGate {
    private(set) var limitedUntil: [EngineID: Date] = [:]
    private var running = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    init() {}

    func markLimited(_ engine: EngineID, until: Date) { limitedUntil[engine] = until }

    /// `true` — слот получен; `false` — задачу отменили, пока она ждала слот (слот не занят, освобождать нечего).
    /// Без этого отменённая сборка висела в очереди до конца чужого вызова и выглядела идущей.
    func acquire(limit: Int) async -> Bool {
        if running < max(limit, 1) {
            running += 1
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) } else { waiters.append((id, continuation)) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Слот передаётся ждущему, если после уменьшения предела в настройках ещё есть место; иначе освобождается.
    func release(limit: Int) {
        if !waiters.isEmpty, running <= max(limit, 1) {
            waiters.removeFirst().continuation.resume(returning: true)
        } else {
            running -= 1
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}

/// Выбор движка, повторы и переход на запасной (SPEC, разделы 2.5–2.6), ограничение параллельных вызовов.
actor EngineRouter {
    struct Settings: Sendable {
        var autoFallback = true
        var maxParallel = 2
        /// Сколько считать основной движок занятым лимитом, если время сброса неизвестно.
        var unknownLimitCooldown: TimeInterval = 15 * 60
    }

    /// Что произошло с запросом, для прогресса в интерфейсе.
    enum Event: Sendable, Equatable {
        case started(EngineID)
        case retrying(EngineID, AIError)
        case switchedToFallback(from: EngineID, to: EngineID, AIError)

        /// Движок, который теперь работает; `nil`, если он не сменился.
        var engine: EngineID? {
            switch self {
            case .started(let engine): engine
            case .switchedToFallback(_, let to, _): to
            case .retrying: nil
            }
        }

        /// Примечание для индикатора работы — одно на все центры (распознавание, сборка, материалы).
        var note: String? {
            switch self {
            case .started: nil
            case .retrying(_, let error): "Повтор после ошибки: \(error.userMessage)"
            case .switchedToFallback(_, let to, let error): "\(error.userMessage) Переход на \(to.title)."
            }
        }
    }

    private let primary: any AIEngine
    /// Основной движок — для подписи «Распознаёт …», пока не пришло событие маршрутизатора.
    nonisolated let primaryID: EngineID
    private let fallback: (any AIEngine)?
    private let settings: Settings
    private let now: @Sendable () -> Date
    private let gate: EngineGate

    /// `gate` — общий для приложения (`EngineCenter`); по умолчанию свой (тесты).
    init(primary: any AIEngine, fallback: (any AIEngine)?, settings: Settings, gate: EngineGate = EngineGate(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.primary = primary
        primaryID = primary.id
        self.fallback = fallback
        self.settings = settings
        self.gate = gate
        self.now = now
    }

    var limitedUntil: [EngineID: Date] { get async { await gate.limitedUntil } }

    /// Основной движок помечен «лимит до …»: новые задания до этого времени идут на запасной.
    func isLimited(_ engine: EngineID) async -> Bool {
        guard let until = await gate.limitedUntil[engine] else { return false }
        return until > now()
    }

    func run(_ request: AIRequest, onEvent: @Sendable (Event) -> Void = { _ in }) async throws(AIError) -> AIResponse {
        guard await gate.acquire(limit: settings.maxParallel) else { throw .cancelled }
        do {
            let response = try await runAcquired(request, onEvent: onEvent)
            await gate.release(limit: settings.maxParallel)
            return response
        } catch {
            await gate.release(limit: settings.maxParallel)
            throw error
        }
    }

    private func runAcquired(_ request: AIRequest, onEvent: @Sendable (Event) -> Void) async throws(AIError) -> AIResponse {
        if Task.isCancelled { throw .cancelled }

        if request.cloudOnly, !primary.id.isCloud {
            throw .invalidOutput("Это действие работает только через облачный движок: Claude Code, Codex или Gemini. "
                + "Выберите «Авто», «Только Claude», «Только Codex» или «Только Gemini» в меню «Модель».")
        }
        // Для облачных действий локальная модель не может быть запасной.
        let canFallback = settings.autoFallback && (fallback.map { !request.cloudOnly || $0.id.isCloud } ?? false)
        if canFallback, await isLimited(primary.id), let fallback {
            onEvent(.started(fallback.id))
            return try await runWithRetry(fallback, request, onEvent: onEvent)
        }

        onEvent(.started(primary.id))
        do {
            return try await runWithRetry(primary, request, onEvent: onEvent)
        } catch {
            guard canFallback, let fallback, Self.shouldFallBack(after: error) else { throw error }
            onEvent(.switchedToFallback(from: primary.id, to: fallback.id, error))
            return try await runWithRetry(fallback, request, onEvent: onEvent)
        }
    }

    /// Модель, выбранная для одного движка, на другом не используется (алиас Claude «opus» не годится для Codex).
    static func prepared(_ request: AIRequest, for engine: any AIEngine) -> AIRequest {
        guard let modelEngine = request.modelEngine, modelEngine != engine.id else { return request }
        var copy = request
        copy.model = nil
        return copy
    }

    /// Лимит — сразу; таймаут, пустой или невалидный ответ — после повтора. Нет бинарника или входа — без перехода.
    static func shouldFallBack(after error: AIError) -> Bool {
        switch error {
        case .rateLimited: true
        default: error.isRetryable
        }
    }

    /// Один повтор на том же движке для таймаута, пустого или невалидного ответа и сбоя процесса.
    private func runWithRetry(_ engine: any AIEngine, _ request: AIRequest,
                              onEvent: @Sendable (Event) -> Void) async throws(AIError) -> AIResponse {
        do {
            return try await engine.run(Self.prepared(request, for: engine))
        } catch {
            if case .rateLimited(let resetAt, _) = error {
                await gate.markLimited(engine.id, until: resetAt ?? now().addingTimeInterval(settings.unknownLimitCooldown))
                throw error
            }
            guard error.isRetryable, !Task.isCancelled else { throw error }
            onEvent(.retrying(engine.id, error))
            do {
                return try await engine.run(Self.prepared(request, for: engine))
            } catch {
                if case .rateLimited(let resetAt, _) = error {
                    await gate.markLimited(engine.id, until: resetAt ?? now().addingTimeInterval(settings.unknownLimitCooldown))
                }
                throw error
            }
        }
    }
}
