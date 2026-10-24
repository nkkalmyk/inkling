import Foundation
import Observation

/// Индекс учебников для интерфейса: запуск фоновой индексации, прогресс, состояние книг и поиск выдержек для сборки.
@MainActor
@Observable
final class LiteratureCenter {
    private(set) var books: [LiteratureBookInfo] = []
    private(set) var progress: LiteratureIndexer.Progress?
    private(set) var isIndexing = false
    private(set) var lastSummary: LiteratureIndexer.Summary?
    private(set) var errorMessage: String?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let storeURL: URL
    @ObservationIgnored private var cachedStore: LiteratureStore?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(settings: AppSettings, storeURL: URL = LiteratureStore.defaultURL) {
        self.settings = settings
        self.storeURL = storeURL
    }

    private func store() throws -> LiteratureStore {
        if let cachedStore { return cachedStore }
        let opened = try LiteratureStore(url: storeURL)
        cachedStore = opened
        return opened
    }

    // MARK: Состояние

    /// Читает список книг индекса; если в настройках книг ещё нет, а в индексе они есть (проиндексированы заранее),
    /// настройки заполняются по индексу.
    func refresh() {
        Task {
            do {
                let indexed = try await store().books()
                books = indexed
                if settings.literatureCollections.isEmpty, !indexed.isEmpty { adopt(indexed) }
            } catch {
                errorMessage = "Не удалось открыть индекс учебников: \(error.localizedDescription)"
            }
        }
    }

    private func adopt(_ indexed: [LiteratureBookInfo]) {
        var collections: [String: [String]] = [:]
        for book in indexed { collections[book.subject, default: []].append(book.path) }
        settings.literatureCollections = collections
        if settings.literatureSubjectCollections.isEmpty { settings.literatureSubjectCollections = Self.defaultMapping(collections.keys) }
    }

    /// Предметы по названию привязываются к коллекциям: «математика» и «химия».
    static func defaultMapping(_ collections: some Collection<String>) -> [String: String] {
        var map: [String: String] = [:]
        for collection in collections {
            let key = collection.lowercased()
            if key.contains("матем") {
                for subject in ["Математический анализ", "Высшая алгебра", "Дискретная математика"] { map[subject] = collection }
            } else if key.contains("хим") {
                map["Общая и неорганическая химия"] = collection
            }
        }
        return map
    }

    func info(forPath path: String) -> LiteratureBookInfo? { books.first { $0.path == path } }

    // MARK: Индексация

    func startIndexing() {
        guard !isIndexing else { return }
        let list = settings.literatureCollections.flatMap { collection, paths in
            paths.map { LiteratureIndexer.Book(url: URL(fileURLWithPath: $0), subject: collection) }
        }
        guard !list.isEmpty else { return }
        isIndexing = true
        errorMessage = nil
        task = Task {
            defer {
                isIndexing = false
                progress = nil
                refresh()
            }
            do {
                let store = try store()
                let summary = try await LiteratureIndexer(store: store).index(list) { progress in
                    Task { @MainActor in self.progress = progress }
                }
                lastSummary = summary
            } catch is CancellationError {
            } catch {
                errorMessage = "Индексация остановлена: \(error.localizedDescription)"
            }
        }
    }

    func cancel() { task?.cancel() }

    func clearIndex() {
        Task {
            do {
                try await store().clear()
                books = []
            } catch {
                errorMessage = "Не удалось очистить индекс: \(error.localizedDescription)"
            }
        }
    }

    /// Убирает из индекса книги, которых нет в настройках.
    func removeFromIndex(path: String) {
        Task {
            try? await store().removeBook(path: path)
            refresh()
        }
    }

    // MARK: Выдержки для сборки

    /// Выдержки из учебников коллекции, привязанной к предмету. Пусто, если коллекции нет или поиск не удался.
    func passages(subject: String, topic: String, texts: [String]) async -> [LiteraturePassage] {
        guard settings.literatureEnabled, let collection = settings.literatureSubjectCollections[subject] else { return [] }
        do {
            return try await LiteratureRetrieval.passages(collection: collection, topic: topic, texts: texts, store: try store())
        } catch {
            return []
        }
    }
}
