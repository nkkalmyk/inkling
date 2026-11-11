import Foundation
import Observation

/// Движки, собранные из настроек, и состояние «Проверить подключение».
@MainActor
@Observable
final class EngineCenter {
    private let settings: AppSettings
    private let secrets: any SecretStore
    /// Имя записи в связке ключей.
    nonisolated static let geminiKeyAccount = "gemini-api-key"
    /// Есть ли ключ Gemini; обновляется `refreshGeminiKey()`, чтобы не трогать связку ключей при запуске.
    private(set) var geminiKeyStored = false
    private(set) var checking: Set<EngineID> = []
    private(set) var reports: [EngineID: ConnectionReport] = [:]
    /// Модели, установленные в Ollama, для списка в настройках.
    private(set) var ollamaModels: [String] = []
    private(set) var ollamaModelsError: AIError?
    private(set) var loadingOllamaModels = false
    private var cachedRouter: (key: String, router: EngineRouter)?

    /// Порог сборки по частям для локального движка (SPEC, раздел 13, этап 8).
    static let localChunkThreshold = 15_000

    init(settings: AppSettings, secrets: any SecretStore = KeychainSecretStore()) {
        self.settings = settings
        self.secrets = secrets
    }

    /// Основной движок не готов на этом Mac: нет программы или ключа. Для подсказки при запуске (C26, аудит 2026-11):
    /// раньше об этом узнавали, только когда распознавание первых фото падало. Вход в аккаунт так не проверить —
    /// для этого нужен вызов модели, а он тратит лимит.
    private(set) var setupProblem: String?

    /// Дешёвая проверка: поиск программы (или ключа Gemini), без вызова модели.
    func checkSetup(locator: BinaryLocator = .live) async {
        let primary = routing.primary
        let found: Bool
        switch primary {
        case .claude: found = (try? await locator.locate("claude", manualPath: settings.claudePathOverride)) != nil
        case .codex: found = (try? await locator.locate("codex", manualPath: settings.codexPathOverride)) != nil
        case .ollama: found = (try? await locator.locate("ollama", manualPath: settings.ollamaPathOverride)) != nil
        case .gemini:
            refreshGeminiKey()
            found = geminiKeyStored
        }
        setupProblem = found ? nil : primary == .gemini
            ? "Не задан ключ Gemini: распознавание и сборка не заработают. Вставьте ключ в настройках (вкладка «Движок»)."
            : "Не найден \(primary.title): распознавание и сборка не заработают. Установите его или укажите путь в настройках (вкладка «Движок»)."
    }

    func dismissSetupProblem() { setupProblem = nil }

    func refreshGeminiKey() {
        geminiKeyStored = secrets.read(account: Self.geminiKeyAccount) != nil
    }

    /// Сохраняет ключ (пустая строка удаляет). Возвращает `false`, если связка ключей отказала.
    @discardableResult
    func saveGeminiKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { refreshGeminiKey() }
        guard !trimmed.isEmpty else {
            secrets.delete(account: Self.geminiKeyAccount)
            return true
        }
        return secrets.write(trimmed, account: Self.geminiKeyAccount)
    }

    func engine(_ id: EngineID) -> any AIEngine {
        switch id {
        case .claude:
            ClaudeCodeEngine(config: .init(manualPath: settings.claudePathOverride,
                                           model: settings.claudeModel.isEmpty ? "sonnet" : settings.claudeModel,
                                           keepTempOnError: settings.keepTempFoldersOnError))
        case .codex:
            CodexEngine(config: .init(manualPath: settings.codexPathOverride, model: settings.codexModel,
                                      keepTempOnError: settings.keepTempFoldersOnError))
        case .gemini:
            GeminiEngine(config: .init(model: settings.geminiModel.isEmpty ? GeminiEngine.Config.defaultModel : settings.geminiModel),
                         apiKey: { [secrets] in secrets.read(account: Self.geminiKeyAccount) })
        case .ollama:
            OllamaEngine(config: .init(manualPath: settings.ollamaPathOverride,
                                       model: settings.ollamaModel.isEmpty ? OllamaEngine.Config.defaultModel
                                                                           : settings.ollamaModel))
        }
    }

    /// Какие движки работают с учётом ручного выбора на панели лекции.
    static func routing(mode: AppSettings.EngineMode, primary: AppSettings.Engine,
                        fallback: AppSettings.Engine) -> (primary: EngineID, fallback: EngineID?) {
        switch mode {
        case .claudeOnly: return (.claude, nil)
        case .codexOnly: return (.codex, nil)
        case .geminiOnly: return (.gemini, nil)
        case .localOnly: return (.ollama, nil)
        case .auto:
            let main = primary.engineID ?? .claude
            let spare = fallback.engineID.flatMap { $0 == main ? nil : $0 }
            return (main, spare)
        }
    }

    var routing: (primary: EngineID, fallback: EngineID?) {
        Self.routing(mode: settings.engineMode, primary: settings.primaryEngine, fallback: settings.fallbackEngine)
    }

    /// Порог сборки по частям: на локальном движке длинный вызов слишком долгий, поэтому порог ниже.
    var chunkThreshold: Int {
        routing.primary == .ollama ? min(settings.chunkThresholdChars, Self.localChunkThreshold) : settings.chunkThresholdChars
    }

    /// Один на всё приложение: при пересоздании маршрутизатора ограничение вызовов и пометки лимита сохраняются.
    @ObservationIgnored private let gate = EngineGate()

    /// Маршрутизатор с текущими настройками. Пересоздаётся при их изменении; счётчик вызовов и пометки «лимит до …»
    /// общие (`gate`).
    var router: EngineRouter {
        let routing = routing
        let key = [routing.primary.rawValue, routing.fallback?.rawValue ?? "-", "\(settings.autoFallback)",
                   "\(settings.maxParallelCalls)", settings.claudePathOverride, settings.claudeModel,
                   settings.codexPathOverride, settings.codexModel, settings.geminiModel, settings.ollamaPathOverride, settings.ollamaModel,
                   "\(settings.keepTempFoldersOnError)"].joined(separator: "|")
        if let cachedRouter, cachedRouter.key == key { return cachedRouter.router }
        let router = EngineRouter(primary: engine(routing.primary),
                                  fallback: routing.fallback.map(engine),
                                  settings: .init(autoFallback: settings.autoFallback,
                                                  maxParallel: settings.maxParallelCalls),
                                  gate: gate)
        cachedRouter = (key, router)
        return router
    }

    func checkConnection(_ id: EngineID) {
        guard !checking.contains(id) else { return }
        checking.insert(id)
        reports[id] = nil
        let engine = engine(id)
        Task {
            let report = await engine.checkConnection()
            reports[id] = report
            checking.remove(id)
            if id == .ollama, report.error == nil { refreshOllamaModels() }
        }
    }

    /// Обновляет список установленных моделей Ollama (при необходимости запускает сервер).
    func refreshOllamaModels() {
        guard !loadingOllamaModels, let engine = engine(.ollama) as? OllamaEngine else { return }
        loadingOllamaModels = true
        Task {
            do throws(AIError) {
                ollamaModels = try await engine.installedModels()
                ollamaModelsError = nil
            } catch {
                ollamaModelsError = error
            }
            loadingOllamaModels = false
        }
    }
}
