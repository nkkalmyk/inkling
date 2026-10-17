import Foundation
import Observation

/// Настройки приложения в `UserDefaults` (SPEC, раздел 9). На этапе 1 большая часть — заготовка:
/// значения сохраняются, но использоваться начнут на следующих этапах.
@MainActor
@Observable
final class AppSettings {
    enum Engine: String, CaseIterable, Identifiable {
        case claude
        case codex
        case ollama
        case none

        var id: String { rawValue }

        var title: String {
            switch self {
            case .claude: EngineID.claude.title
            case .codex: EngineID.codex.title
            case .ollama: EngineID.ollama.title
            case .none: "Нет"
            }
        }

        /// Название в списках выбора; непроверенный движок помечен.
        var pickerTitle: String {
            engineID?.isUnverified == true ? "\(title) — не проверен вживую" : title
        }

        var engineID: EngineID? {
            switch self {
            case .claude: .claude
            case .codex: .codex
            case .ollama: .ollama
            case .none: nil
            }
        }
    }

    /// Ручной выбор движка для новых запусков (меню «Модель» на панели лекции).
    enum EngineMode: String, CaseIterable, Identifiable {
        /// Основной движок, при лимите или сбое — запасной.
        case auto
        case claudeOnly
        case codexOnly
        case localOnly

        var id: String { rawValue }

        var title: String {
            switch self {
            case .auto: "Авто"
            case .claudeOnly: "Только Claude"
            case .codexOnly: "Только Codex"
            case .localOnly: "Только локальная"
            }
        }
    }

    /// Модели Claude Code в списке настроек (алиасы CLI). Любую другую можно вписать вручную.
    static let claudeModels: [(id: String, title: String)] = [("sonnet", "Sonnet"), ("opus", "Opus"), ("haiku", "Haiku")]

    static var defaultStorageRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inkling", isDirectory: true)
    }

    private let defaults: UserDefaults

    var storageRootPath: String { didSet { defaults.set(storageRootPath, forKey: Keys.storageRootPath) } }
    var primaryEngine: Engine { didSet { defaults.set(primaryEngine.rawValue, forKey: Keys.primaryEngine) } }
    var fallbackEngine: Engine { didSet { defaults.set(fallbackEngine.rawValue, forKey: Keys.fallbackEngine) } }
    var autoFallback: Bool { didSet { defaults.set(autoFallback, forKey: Keys.autoFallback) } }
    var claudePathOverride: String { didSet { defaults.set(claudePathOverride, forKey: Keys.claudePathOverride) } }
    var claudeModel: String { didSet { defaults.set(claudeModel, forKey: Keys.claudeModel) } }
    var engineMode: EngineMode { didSet { defaults.set(engineMode.rawValue, forKey: Keys.engineMode) } }
    var codexPathOverride: String { didSet { defaults.set(codexPathOverride, forKey: Keys.codexPathOverride) } }
    /// Пусто — модель выбирает сам Codex.
    var codexModel: String { didSet { defaults.set(codexModel, forKey: Keys.codexModel) } }
    var ollamaPathOverride: String { didSet { defaults.set(ollamaPathOverride, forKey: Keys.ollamaPathOverride) } }
    var ollamaModel: String { didSet { defaults.set(ollamaModel, forKey: Keys.ollamaModel) } }
    var pageTimeoutSeconds: Int { didSet { defaults.set(pageTimeoutSeconds, forKey: Keys.pageTimeoutSeconds) } }
    var maxParallelCalls: Int { didSet { defaults.set(maxParallelCalls, forKey: Keys.maxParallelCalls) } }
    var chunkThresholdChars: Int { didSet { defaults.set(chunkThresholdChars, forKey: Keys.chunkThresholdChars) } }
    var autoStudyMaterials: Bool { didSet { defaults.set(autoStudyMaterials, forKey: Keys.autoStudyMaterials) } }
    var keepTempFoldersOnError: Bool { didSet { defaults.set(keepTempFoldersOnError, forKey: Keys.keepTempFoldersOnError) } }

    var storageRoot: URL { URL(fileURLWithPath: (storageRootPath as NSString).expandingTildeInPath, isDirectory: true) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storageRootPath = defaults.string(forKey: Keys.storageRootPath) ?? Self.defaultStorageRoot.path
        primaryEngine = defaults.string(forKey: Keys.primaryEngine).flatMap(Engine.init(rawValue:)) ?? .claude
        fallbackEngine = defaults.string(forKey: Keys.fallbackEngine).flatMap(Engine.init(rawValue:)) ?? .none
        autoFallback = defaults.object(forKey: Keys.autoFallback) as? Bool ?? true
        claudePathOverride = defaults.string(forKey: Keys.claudePathOverride) ?? ""
        claudeModel = defaults.string(forKey: Keys.claudeModel) ?? "sonnet"
        engineMode = defaults.string(forKey: Keys.engineMode).flatMap(EngineMode.init(rawValue:)) ?? .auto
        codexPathOverride = defaults.string(forKey: Keys.codexPathOverride) ?? ""
        codexModel = defaults.string(forKey: Keys.codexModel) ?? ""
        ollamaPathOverride = defaults.string(forKey: Keys.ollamaPathOverride) ?? ""
        ollamaModel = defaults.string(forKey: Keys.ollamaModel) ?? OllamaEngine.Config.defaultModel
        pageTimeoutSeconds = defaults.object(forKey: Keys.pageTimeoutSeconds) as? Int ?? 120
        maxParallelCalls = min(max(defaults.object(forKey: Keys.maxParallelCalls) as? Int ?? 2, 1), 2)
        chunkThresholdChars = defaults.object(forKey: Keys.chunkThresholdChars) as? Int ?? 40_000
        autoStudyMaterials = defaults.bool(forKey: Keys.autoStudyMaterials)
        keepTempFoldersOnError = defaults.bool(forKey: Keys.keepTempFoldersOnError)
    }

    private enum Keys {
        static let storageRootPath = "storageRootPath"
        static let primaryEngine = "primaryEngine"
        static let fallbackEngine = "fallbackEngine"
        static let autoFallback = "autoFallback"
        static let claudePathOverride = "claudePathOverride"
        static let claudeModel = "claudeModel"
        static let engineMode = "engineMode"
        static let codexPathOverride = "codexPathOverride"
        static let codexModel = "codexModel"
        static let ollamaPathOverride = "ollamaPathOverride"
        static let ollamaModel = "ollamaModel"
        static let pageTimeoutSeconds = "pageTimeoutSeconds"
        static let maxParallelCalls = "maxParallelCalls"
        static let chunkThresholdChars = "chunkThresholdChars"
        static let autoStudyMaterials = "autoStudyMaterials"
        static let keepTempFoldersOnError = "keepTempFoldersOnError"
    }
}
