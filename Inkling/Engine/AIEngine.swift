import Foundation

/// Идентификатор движка. В v1 есть только Claude Code (SPEC, раздел 13).
enum EngineID: String, Codable, Sendable, CaseIterable {
    case claude

    var title: String {
        switch self {
        case .claude: "Claude Code"
        }
    }
}

/// Запрос к модели (SPEC, раздел 2.1).
struct AIRequest: Sendable {
    enum Format: Sendable, Equatable {
        case text
        /// JSON; со схемой CLI сам проверяет структуру (`--json-schema`), без схемы JSON извлекается из текста.
        case json(schema: String?)
    }

    var prompt: String
    var systemPrompt: String
    /// Картинки копируются во временную папку запуска; в промпте на них ссылаются как `./<имя файла>`.
    var images: [URL] = []
    var format: Format = .text
    var timeout: TimeInterval = 120
    /// `nil` — модель из настроек движка.
    var model: String?
}

struct AIResponse: Sendable, Equatable {
    var text: String
    /// JSON-ответ (для `.json`).
    var json: Data?
    var engine: EngineID
    /// Фактическая модель, как её назвал CLI.
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
            return "Claude Code завершился с ошибкой (код \(code))."
        }
    }

    /// Сырые подробности для раскрывающегося блока.
    var details: String {
        switch self {
        case .binaryNotFound(let s), .notAuthenticated(let s), .invalidOutput(let s): s
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

/// Движок, выполняющий запросы к модели через установленный CLI.
protocol AIEngine: Sendable {
    var id: EngineID { get }
    func run(_ request: AIRequest) async throws(AIError) -> AIResponse
    func checkConnection() async -> ConnectionReport
}
