import Foundation

/// Идентификатор движка: Claude Code и локальная Ollama (SPEC, раздел 13).
enum EngineID: String, Codable, Sendable, CaseIterable {
    case claude
    case ollama

    var title: String {
        switch self {
        case .claude: "Claude Code"
        case .ollama: "Ollama (локально)"
        }
    }

    /// Результат локальной модели нужно проверить: на плотной рукописи она ошибается заметно чаще Claude.
    var needsReview: Bool { self == .ollama }
}

/// Запрос к модели (SPEC, раздел 2.1).
struct AIRequest: Sendable {
    enum Format: Sendable, Equatable {
        case text
        /// JSON; со схемой движок сам держит структуру (`--json-schema`, `format` у Ollama), без схемы JSON извлекается из текста.
        case json(schema: String?)
    }

    var prompt: String
    var systemPrompt: String
    /// Claude: картинки копируются во временную папку запуска, в промпте на них ссылаются как `./<имя файла>`.
    /// Ollama: картинки уходят в запрос в base64.
    var images: [URL] = []
    var format: Format = .text
    var timeout: TimeInterval = 120
    /// `nil` — модель из настроек движка.
    var model: String?
    /// Запрос выполняет только этот движок: без перехода на запасной и без запуска на другом.
    var requiredEngine: EngineID?
}

struct AIResponse: Sendable, Equatable {
    var text: String
    /// JSON-ответ (для `.json`).
    var json: Data?
    var engine: EngineID
    /// Фактическая модель, как её назвал движок.
    var model: String
    var duration: TimeInterval
}

/// Ошибки движков (SPEC, раздел 2.1). У каждой есть понятное русское сообщение и сырые подробности.
enum AIError: Error, Equatable, Sendable {
    case binaryNotFound(String)
    case notAuthenticated(String)
    case rateLimited(resetAt: Date?, details: String)
    case timeout
    case cancelled
    case invalidOutput(String)
    case processFailed(exitCode: Int32, stderr: String)
    /// Ollama: нет бинарника или сервер не поднялся.
    case ollamaUnavailable(String)
    /// Ollama: выбранной модели нет среди установленных.
    case modelNotInstalled(model: String)

    /// Повтор на том же движке имеет смысл (SPEC, раздел 2.6).
    var isRetryable: Bool {
        switch self {
        case .timeout, .invalidOutput: true
        case .processFailed: !isModelUnavailable
        default: false
        }
    }

    /// CLI сообщил, что выбранная модель недоступна (по заметкам этапа 0 — `processFailed` с особым текстом).
    var isModelUnavailable: Bool {
        guard case .processFailed(_, let stderr) = self else { return false }
        let text = stderr.lowercased()
        return text.contains("issue with the selected model") || text.contains("unrecognized_model")
    }

    var userMessage: String {
        switch self {
        case .binaryNotFound:
            return "Не найден Claude Code. Установите его или укажите путь к claude в настройках (вкладка «Движок»)."
        case .notAuthenticated:
            return "Claude Code не выполнил вход. Откройте Терминал, запустите claude и войдите в аккаунт, затем повторите."
        case .rateLimited(let resetAt, _):
            if let resetAt {
                return "Исчерпан лимит подписки. Он восстановится в \(resetAt.formatted(Self.timeFormat))."
            }
            return "Исчерпан лимит подписки. Попробуйте позже."
        case .timeout:
            return "Модель не ответила вовремя. Можно увеличить таймаут в настройках."
        case .cancelled:
            return "Отменено."
        case .invalidOutput:
            return "Модель вернула пустой ответ или ответ в неожиданном формате."
        case .processFailed(let code, _):
            if isModelUnavailable { return "Выбранная модель недоступна. Укажите другую в настройках (вкладка «Движок»)." }
            return "Движок завершился с ошибкой (код \(code))."
        case .ollamaUnavailable:
            return "Ollama недоступна. Установите её (brew install ollama) или укажите путь к ollama в настройках (вкладка «Движок»)."
        case .modelNotInstalled(let model):
            return "Модель «\(model)» не установлена в Ollama. Выберите другую в настройках или создайте её (см. docs/ollama)."
        }
    }

    /// Сырые подробности для раскрывающегося блока.
    var details: String {
        switch self {
        case .binaryNotFound(let s), .notAuthenticated(let s), .invalidOutput(let s), .ollamaUnavailable(let s): s
        case .modelNotInstalled(let model): model
        case .rateLimited(_, let s): s
        case .processFailed(_, let stderr): stderr
        case .timeout, .cancelled: ""
        }
    }

    private static let timeFormat = Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: "ru_RU"))
}

/// Результат «Проверить подключение».
struct ConnectionReport: Sendable, Equatable {
    var binaryPath: String?
    var binarySource: String?
    var version: String?
    var model: String?
    var duration: TimeInterval?
    var error: AIError?

    var isOK: Bool { error == nil && model != nil }
}

/// Движок, выполняющий запросы к модели: через установленный CLI или локальный сервер.
protocol AIEngine: Sendable {
    var id: EngineID { get }
    func run(_ request: AIRequest) async throws(AIError) -> AIResponse
    func checkConnection() async -> ConnectionReport
}
