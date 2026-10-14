import Foundation
import Observation

/// Движки, собранные из настроек, и состояние «Проверить подключение».
@MainActor
@Observable
final class EngineCenter {
    private let settings: AppSettings
    private(set) var checking: Set<EngineID> = []
    private(set) var reports: [EngineID: ConnectionReport] = [:]
    private var cachedRouter: (key: String, router: EngineRouter)?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func engine(_ id: EngineID) -> any AIEngine {
        switch id {
        case .claude:
            ClaudeCodeEngine(config: .init(manualPath: settings.claudePathOverride,
                                           model: settings.claudeModel.isEmpty ? "sonnet" : settings.claudeModel,
                                           keepTempOnError: settings.keepTempFoldersOnError))
        }
    }

    /// Маршрутизатор с текущими настройками. Пересоздаётся при их изменении (пометки «лимит до …» при этом сбрасываются).
    var router: EngineRouter {
        let key = [settings.primaryEngine.rawValue, settings.fallbackEngine.rawValue, "\(settings.autoFallback)",
                   "\(settings.maxParallelCalls)", settings.claudePathOverride, settings.claudeModel,
                   "\(settings.keepTempFoldersOnError)"].joined(separator: "|")
        if let cachedRouter, cachedRouter.key == key { return cachedRouter.router }
        let router = EngineRouter(primary: engine(.claude),
                                  fallback: nil,
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
        }
    }
}
