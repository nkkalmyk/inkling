import Foundation
import Observation

/// Движки, собранные из настроек, и состояние «Проверить подключение».
@MainActor
@Observable
final class EngineCenter {
    private let settings: AppSettings
    private(set) var checking: Set<EngineID> = []
    private(set) var reports: [EngineID: ConnectionReport] = [:]
    /// Модели, установленные в Ollama, для списка в настройках.
    private(set) var ollamaModels: [String] = []
    private(set) var ollamaModelsError: AIError?
    private(set) var loadingOllamaModels = false
    private var cachedRouter: (key: String, router: EngineRouter)?

    /// Порог сборки по частям для локального движка (SPEC, раздел 13, этап 8).
    static let localChunkThreshold = 15_000

    init(settings: AppSettings) {
        self.settings = settings
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

    /// Маршрутизатор с текущими настройками. Пересоздаётся при их изменении (пометки «лимит до …» при этом сбрасываются).
    var router: EngineRouter {
        let routing = routing
        let key = [routing.primary.rawValue, routing.fallback?.rawValue ?? "-", "\(settings.autoFallback)",
                   "\(settings.maxParallelCalls)", settings.claudePathOverride, settings.claudeModel,
                   settings.codexPathOverride, settings.codexModel, settings.ollamaPathOverride, settings.ollamaModel,
                   "\(settings.keepTempFoldersOnError)"].joined(separator: "|")
        if let cachedRouter, cachedRouter.key == key { return cachedRouter.router }
        let router = EngineRouter(primary: engine(routing.primary),
                                  fallback: routing.fallback.map(engine),
                                  settings: .init(autoFallback: settings.autoFallback,
                                                  maxParallel: settings.maxParallelCalls))
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
