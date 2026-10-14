import Foundation

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
    }

    private let primary: any AIEngine
    private let fallback: (any AIEngine)?
    private let settings: Settings
    private let now: @Sendable () -> Date
    private(set) var limitedUntil: [EngineID: Date] = [:]
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(primary: any AIEngine, fallback: (any AIEngine)?, settings: Settings,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.primary = primary
        self.fallback = fallback
        self.settings = settings
        self.now = now
    }

    /// Основной движок помечен «лимит до …»: новые задания до этого времени идут на запасной.
    func isLimited(_ engine: EngineID) -> Bool {
        guard let until = limitedUntil[engine] else { return false }
        return until > now()
    }

    func run(_ request: AIRequest, onEvent: @Sendable (Event) -> Void = { _ in }) async throws(AIError) -> AIResponse {
        await acquire()
        defer { release() }
        if Task.isCancelled { throw .cancelled }

        let canFallback = settings.autoFallback && fallback != nil
        if canFallback, isLimited(primary.id), let fallback {
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
            return try await engine.run(request)
        } catch {
            if case .rateLimited(let resetAt, _) = error {
                limitedUntil[engine.id] = resetAt ?? now().addingTimeInterval(settings.unknownLimitCooldown)
                throw error
            }
            guard error.isRetryable, !Task.isCancelled else { throw error }
            onEvent(.retrying(engine.id, error))
            do {
                return try await engine.run(request)
            } catch {
                if case .rateLimited(let resetAt, _) = error {
                    limitedUntil[engine.id] = resetAt ?? now().addingTimeInterval(settings.unknownLimitCooldown)
                }
                throw error
            }
        }
    }

    // MARK: Не больше `maxParallel` вызовов одновременно

    private func acquire() async {
        if running < max(settings.maxParallel, 1) {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
