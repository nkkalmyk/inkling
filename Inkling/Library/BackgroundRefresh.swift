import Foundation

/// Учёт фонового пересчёта по лекциям: пересчёт запускается, только когда ключ (ревизия, описание в `meta.json`)
/// сменился, а прежний пересчёт той же лекции отменяется. Результаты центры хранят сами: так экраны наблюдают
/// только их, а не служебные ключи (иначе чтение из `body` вызывало бы новую перерисовку).
@MainActor
final class BackgroundRefresh<Key: Equatable> {
    private var keys: [UUID: Key] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func isCurrent(_ id: UUID, key: Key) -> Bool { keys[id] == key }

    /// Запускает `work`, если ключ лекции сменился. `work` пишет результат, только пока ключ тот же (`isCurrent`).
    func refresh(_ id: UUID, key: Key, cancelPrevious: Bool = true, _ work: @escaping @MainActor () async -> Void) {
        guard keys[id] != key else { return }
        keys[id] = key
        if cancelPrevious { tasks[id]?.cancel() }
        tasks[id] = Task { await work() }
    }

    /// Следующий запрос пересчитает заново, даже с тем же ключом.
    func invalidate(_ id: UUID) { keys[id] = nil }
}
