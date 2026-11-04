import CoreImage
import Foundation

/// Gemini через HTTP API Google AI Studio по ключу пользователя (SPEC, раздел 13).
/// Вход по подписке Google AI Pro недоступен: Gemini CLI и Antigravity отказывают, а условия Google запрещают
/// пользоваться чужим OAuth-входом из сторонних приложений (docs/PROBLEMS.md). Поэтому только ключ.
struct GeminiEngine: AIEngine {
    struct Config: Sendable {
        var model = Self.defaultModel
        var baseURL = URL(string: "https://generativelanguage.googleapis.com")!

        /// Основная модель: на 10 отложенных страницах расходится с текстом Claude меньше всех стабильных (docs/cli-notes.md).
        static let defaultModel = "gemini-3.5-flash"
        /// Запасная модель внутри движка: отвечала на каждый запрос, когда обычные Flash отдавали 429 и 503.
        static let spareModel = "gemini-flash-lite-latest"
    }

    /// HTTP-транспорт; в тестах подменяется.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    let id = EngineID.gemini
    var config = Config()
    /// Ключ читается при каждом вызове: его можно сменить в настройках без пересоздания движка.
    var apiKey: @Sendable () -> String?
    var transport: Transport = { try await URLSession.shared.data(for: $0) }
    var now: @Sendable () -> Date = { Date() }

    /// Если в 429 нет `retryDelay`, считаем лимит минутным и пробуем снова через минуту.
    static let defaultLimitDelay: TimeInterval = 60

    // MARK: Запрос

    /// Тело `generateContent`. Системный промпт распознавания в приложении написан для Claude («читай инструментом Read»),
    /// поэтому для одной страницы берётся промпт переписчика, проверенный на отложенных страницах (как у Ollama).
    /// Схема JSON уходит текстом: `responseSchema` Gemini понимает лишь часть JSON Schema и отвечает 400 на остальное.
    static func requestBody(_ request: AIRequest, images: [Data]) -> Data {
        var system = request.systemPrompt
        var prompt = request.prompt
        if images.count == 1, request.systemPrompt == PromptLibrary.recognitionSystemPrompt {
            system = OllamaEngine.recognitionSystemPrompt
            prompt = OllamaEngine.localRecognitionPrompt(prompt)
        } else {
            system = system.replacingOccurrences(of: "читай инструментом Read по указанному имени файла",
                                                 with: "смотри в приложенных к запросу изображениях")
        }
        var generation: [String: Any] = ["temperature": 0]
        if case .json(let schema) = request.format {
            generation["responseMimeType"] = "application/json"
            system += schema.map { "\n\nОтвет — только JSON-объект по этой JSON-схеме, без текста вокруг:\n\($0)" }
                ?? "\n\nОтвет — только JSON-объект, без текста вокруг."
        }
        var parts: [[String: Any]] = [["text": prompt]]
        parts += images.map { ["inline_data": ["mime_type": "image/jpeg", "data": $0.base64EncodedString()]] }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": generation,
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    /// Картинка для модели: JPEG без увеличения (увеличивать нужно только локальной модели).
    static func preparedImage(_ url: URL) throws(AIError) -> Data {
        do {
            return try ImageProcessor.jpegData(try ImageProcessor.loadOriented(url), quality: 0.9)
        } catch {
            throw .invalidOutput("Не удалось подготовить картинку \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func endpoint(model: String) -> URL {
        config.baseURL.appendingPathComponent("v1beta/models/\(model):generateContent")
    }

    // MARK: Разбор ответа

    static func parse(data: Data, status: Int, format: AIRequest.Format, requestedModel: String,
                      duration: TimeInterval, now: Date = Date()) -> Result<AIResponse, AIError> {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let body = String(decoding: data, as: UTF8.self)
        guard status == 200 else {
            return .failure(failure(status: status, json: json, body: body, model: requestedModel, now: now))
        }
        guard let json else { return .failure(.invalidOutput("Ответ Gemini не в ожидаемом формате:\n" + String(body.prefix(2000)))) }
        if let block = (json["promptFeedback"] as? [String: Any])?["blockReason"] as? String {
            return .failure(.invalidOutput("Gemini отказался отвечать на запрос: \(block)."))
        }
        guard let candidate = (json["candidates"] as? [[String: Any]])?.first else {
            return .failure(.invalidOutput("В ответе Gemini нет вариантов:\n" + String(body.prefix(2000))))
        }
        let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let text = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            let reason = candidate["finishReason"] as? String ?? "?"
            return .failure(.invalidOutput("Пустой ответ модели (finishReason: \(reason))."))
        }
        if candidate["finishReason"] as? String == "MAX_TOKENS" {
            return .failure(.invalidOutput("Ответ модели обрезан: закончился лимит длины.\n" + String(text.suffix(500))))
        }
        let model = json["modelVersion"] as? String ?? requestedModel
        switch format {
        case .text:
            return .success(AIResponse(text: text, json: nil, engine: .gemini, model: model, duration: duration))
        case .json:
            guard let object = JSONExtractor.object(in: text) else {
                return .failure(.invalidOutput("В ответе модели нет JSON:\n" + String(text.prefix(2000))))
            }
            return .success(AIResponse(text: text, json: object, engine: .gemini, model: model, duration: duration))
        }
    }

    /// Ошибка API → `AIError`. Лимит и перегрузка различаются: 429 — квота ключа, 503 — перегрузка модели.
    static func failure(status: Int, json: [String: Any]?, body: String, model: String, now: Date) -> AIError {
        let error = json?["error"] as? [String: Any]
        let message = error?["message"] as? String ?? body
        let code = error?["status"] as? String ?? ""
        let lower = message.lowercased()
        if status == 429 || code == "RESOURCE_EXHAUSTED" {
            let delay = retryDelay(in: error) ?? defaultLimitDelay
            return .rateLimited(resetAt: now.addingTimeInterval(delay), details: message)
        }
        if status == 401 || status == 403 || code == "UNAUTHENTICATED" || code == "PERMISSION_DENIED" || lower.contains("api key") {
            return .geminiNotAuthenticated(message)
        }
        if status == 404 { return .geminiModelUnavailable(model: model) }
        return .processFailed(exitCode: Int32(status), stderr: message)
    }

    /// `error.details[].retryDelay` вида `"34s"` или `"34.5s"`.
    static func retryDelay(in error: [String: Any]?) -> TimeInterval? {
        let details = error?["details"] as? [[String: Any]] ?? []
        for item in details {
            if let text = item["retryDelay"] as? String, let seconds = Double(text.dropLast()), text.hasSuffix("s") {
                return seconds
            }
        }
        return nil
    }

    /// Какие ошибки основной модели стоит попробовать на запасной: у моделей разные квоты и нагрузка.
    static func shouldTrySpareModel(after error: AIError) -> Bool {
        switch error {
        case .rateLimited, .geminiModelUnavailable, .timeout: true
        case .processFailed(let code, _): code >= 500
        default: false
        }
    }

    // MARK: Запуск

    func run(_ request: AIRequest) async throws(AIError) -> AIResponse {
        guard let key = apiKey(), !key.isEmpty else {
            throw .geminiNotAuthenticated("Ключ Gemini не задан.")
        }
        var images: [Data] = []
        for url in request.images { images.append(try Self.preparedImage(url)) }
        let body = Self.requestBody(request, images: images)

        let wanted = request.model.flatMap { $0.isEmpty ? nil : $0 } ?? config.model
        let models = wanted == Config.spareModel ? [wanted] : [wanted, Config.spareModel]
        var lastError: AIError = .invalidOutput("Нет ответа Gemini.")
        for model in models {
            do {
                return try await attempt(model: model, key: key, body: body, request: request)
            } catch {
                lastError = error
                guard model != models.last, Self.shouldTrySpareModel(after: error) else { throw error }
            }
        }
        throw lastError
    }

    private func attempt(model: String, key: String, body: Data, request: AIRequest) async throws(AIError) -> AIResponse {
        var http = URLRequest(url: endpoint(model: model))
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        http.httpBody = body
        http.timeoutInterval = request.timeout
        let started = Date()
        let (data, status) = try await Self.send(http, timeout: request.timeout, transport: transport)
        return try Self.parse(data: data, status: status, format: request.format, requestedModel: model,
                              duration: Date().timeIntervalSince(started), now: now()).get()
    }

    /// Запрос с общим таймаутом (у `URLRequest` таймаут только между пакетами) и отменой.
    static func send(_ request: URLRequest, timeout: TimeInterval,
                     transport: @escaping Transport) async throws(AIError) -> (Data, Int) {
        do {
            return try await withThrowingTaskGroup(of: (Data, Int).self) { group in
                group.addTask {
                    let (data, response) = try await transport(request)
                    return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw AIError.timeout
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } catch let error as AIError {
            throw error
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError { throw .cancelled }
            if (error as? URLError)?.code == .timedOut { throw .timeout }
            throw .processFailed(exitCode: -1, stderr: "Нет связи с Gemini: \(error.localizedDescription)")
        }
    }

    // MARK: Проверка подключения

    func checkConnection() async -> ConnectionReport {
        var report = ConnectionReport()
        do {
            let response = try await run(AIRequest(prompt: "Ответь одним словом: готово.",
                                                   systemPrompt: "Отвечай очень кратко.", timeout: 60))
            report.model = response.model
            report.duration = response.duration
        } catch {
            report.error = error
        }
        return report
    }
}
