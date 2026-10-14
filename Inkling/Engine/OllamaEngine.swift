import CoreImage
import Foundation

/// Локальная модель через HTTP API Ollama (SPEC, раздел 13, этап 8). Сервер при необходимости запускает `OllamaServer`.
struct OllamaEngine: AIEngine {
    struct Config: Sendable {
        var manualPath: String?
        var model: String = Self.defaultModel
        var baseURL = URL(string: "http://127.0.0.1:11434")!

        static let defaultModel = "inkling-ocr"
    }

    /// HTTP-транспорт; в тестах подменяется.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    let id = EngineID.ollama
    var config: Config
    var server: OllamaServer = .shared
    var transport: Transport = { try await URLSession.shared.data(for: $0) }

    /// Локальная модель в 5–10 раз медленнее Claude: таймауты из настроек и сборки умножаются.
    static let timeoutFactor: Double = 3

    /// Системный промпт распознавания для локальной модели (тот же, что в docs/ollama/inkling-ocr.Modelfile).
    /// Промпт приложения рассчитан на Claude Code («читай картинку инструментом Read») и здесь не подходит.
    static let recognitionSystemPrompt = """
    Ты переписываешь фотографии рукописных конспектов и слайды лекций в Markdown. Ты переписчик, а не редактор: переписывай только то, \
    что видишь на изображении, символ в символ. Не исправляй, не дополняй и не пересчитывай математику, даже если видишь \
    ошибку. Не добавляй своих пояснений, названий преобразований и комментариев. Сокращения оставляй как в конспекте \
    (Д-во, опр-ль, св-во). Если слово, число или символ читается неуверенно, пиши [неразборчиво] вместо догадки. \
    Выведи только Markdown, без блока кода и без вступлений.
    """

    /// Потолок ответа при распознавании. Самая плотная страница в прогоне — ~2 200 токенов; изредка модель срывается
    /// и вместо переписывания сочиняет «учебник» на тысячи токенов. Упёршийся в потолок ответ считается ошибкой
    /// (`done_reason: length`): лучше повтор и сообщение, чем выдуманный текст в конспекте.
    static let recognitionTokenLimit = 4_096

    /// Промпт распознавания для локальной модели: без ссылки «Изображение: ./файл» (картинка уходит в запрос сама)
    /// и без названия предмета. С названием модель изредка не переписывает страницу, а начинает с заголовка-предмета
    /// и сочиняет учебник по нему (воспроизводится на странице алгебры в лекции по химии, docs/local-models.md).
    /// Правила оформления из вставки предмета остаются.
    static func localRecognitionPrompt(_ prompt: String) -> String {
        prompt.replacingOccurrences(of: #"\s*Изображение: \./\S+\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #" по предмету «[^»]*»"#, with: "", options: .regularExpression)
    }

    // MARK: Запрос

    /// Тело `/api/chat`. Рассуждения выключены: на распознавании они в 4–5 раз медленнее и не точнее (docs/local-models.md).
    /// Параметры выборки задаются явно, чтобы и «голая» модель без Modelfile работала как `inkling-ocr`.
    /// `structured: false` — без поля `format`: сборка MLX не умеет ограничивать вывод схемой (ответ 501),
    /// тогда схема уходит текстом в системный промпт, а JSON извлекается и проверяется после ответа.
    static func chatBody(_ request: AIRequest, model: String, images: [Data], structured: Bool = true) -> Data {
        var user: [String: Any] = ["role": "user", "content": request.prompt]
        var system = request.systemPrompt
        if !images.isEmpty {
            user["content"] = localRecognitionPrompt(request.prompt)
            user["images"] = images.map { $0.base64EncodedString() }
            system = recognitionSystemPrompt
        }
        let promptTokens = (request.prompt.count + request.systemPrompt.count) / 2 + images.count * 4_000
        var body: [String: Any] = [
            "model": model,
            "stream": false,
            "think": false,
            "keep_alive": "10m",
            "messages": [["role": "system", "content": system], user],
            "options": [
                "temperature": 0,
                // Штраф за повторы искажает матрицы и индексы, где одни и те же токены идут подряд.
                "presence_penalty": 0,
                "repeat_penalty": 1,
                "num_ctx": min(65_536, max(12_288, promptTokens * 2 + 8_192)),
                "num_predict": images.isEmpty ? 16_384 : recognitionTokenLimit,
            ] as [String: Any],
        ]
        if case .json(let schema) = request.format {
            if !structured {
                let hint = schema.map { "\n\nОтвет — только JSON-объект по этой JSON-схеме, без текста вокруг:\n\($0)" }
                    ?? "\n\nОтвет — только JSON-объект, без текста вокруг."
                body["messages"] = [["role": "system", "content": system + hint], user]
            } else if let schema, let object = try? JSONSerialization.jsonObject(with: Data(schema.utf8)) {
                body["format"] = object
            } else {
                body["format"] = "json"
            }
        }
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    /// Картинка для модели: JPEG, мелкие увеличиваются (`ImageProcessor.upscaledForModel`).
    static func preparedImage(_ url: URL) throws(AIError) -> Data {
        do {
            let image = ImageProcessor.upscaledForModel(try ImageProcessor.loadOriented(url))
            return try ImageProcessor.jpegData(image, quality: 0.9)
        } catch {
            throw .invalidOutput("Не удалось подготовить картинку \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    // MARK: Разбор ответа

    /// Сборка модели не поддерживает `format` (MLX в Ollama 0.40: 501 «structured output is unavailable»).
    static func structuredOutputUnavailable(data: Data, status: Int) -> Bool {
        status == 501 && String(decoding: data, as: UTF8.self).lowercased().contains("structured output")
    }

    static func parse(data: Data, status: Int, format: AIRequest.Format, requestedModel: String,
                      duration: TimeInterval) -> Result<AIResponse, AIError> {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let body = String(decoding: data, as: UTF8.self)
        guard status == 200 else {
            let message = json?["error"] as? String ?? body
            if status == 404 || message.lowercased().contains("not found") && message.lowercased().contains("model") {
                return .failure(.modelNotInstalled(model: requestedModel))
            }
            return .failure(.processFailed(exitCode: Int32(status), stderr: message))
        }
        guard let json, let message = json["message"] as? [String: Any] else {
            return .failure(.invalidOutput("Ответ Ollama не в ожидаемом формате:\n" + String(body.prefix(2000))))
        }
        let content = (message["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let model = json["model"] as? String ?? requestedModel
        guard !content.isEmpty else { return .failure(.invalidOutput("Пустой ответ модели.")) }
        if json["done_reason"] as? String == "length" {
            return .failure(.invalidOutput("Ответ модели обрезан: закончился лимит длины.\n" + String(content.suffix(500))))
        }
        switch format {
        case .text:
            return .success(AIResponse(text: content, json: nil, engine: .ollama, model: model, duration: duration))
        case .json:
            guard let object = JSONExtractor.object(in: content) else {
                return .failure(.invalidOutput("В ответе модели нет JSON:\n" + String(content.prefix(2000))))
            }
            return .success(AIResponse(text: content, json: object, engine: .ollama, model: model, duration: duration))
        }
    }

    // MARK: Запуск

    func run(_ request: AIRequest) async throws(AIError) -> AIResponse {
        try await server.ensureRunning(manualPath: config.manualPath, baseURL: config.baseURL, transport: transport)
        var images: [Data] = []
        for url in request.images { images.append(try Self.preparedImage(url)) }
        let model = request.model ?? config.model
        var http = URLRequest(url: config.baseURL.appendingPathComponent("api/chat"))
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.httpBody = Self.chatBody(request, model: model, images: images)
        let timeout = request.timeout * Self.timeoutFactor
        http.timeoutInterval = timeout

        let prepared = http
        // Локальная модель держит один запрос за раз: второй параллельный только удвоит память.
        var unstructured = prepared
        unstructured.httpBody = Self.chatBody(request, model: model, images: images, structured: false)
        let fallbackRequest = unstructured
        return try await server.exclusively { () async throws(AIError) -> AIResponse in
            let started = Date()
            var (data, status) = try await Self.send(prepared, timeout: timeout, transport: transport)
            if Self.structuredOutputUnavailable(data: data, status: status) {
                (data, status) = try await Self.send(fallbackRequest, timeout: timeout, transport: transport)
            }
            return try Self.parse(data: data, status: status, format: request.format, requestedModel: model,
                                  duration: Date().timeIntervalSince(started)).get()
        }
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
            if let urlError = error as? URLError, [.cannotConnectToHost, .networkConnectionLost].contains(urlError.code) {
                throw .ollamaUnavailable("Сервер Ollama перестал отвечать: \(urlError.localizedDescription)")
            }
            throw .processFailed(exitCode: -1, stderr: error.localizedDescription)
        }
    }

    // MARK: Модели и проверка подключения

    /// Установленные модели (`/api/tags`), по алфавиту.
    func installedModels() async throws(AIError) -> [String] {
        try await server.ensureRunning(manualPath: config.manualPath, baseURL: config.baseURL, transport: transport)
        let (data, status) = try await Self.send(URLRequest(url: config.baseURL.appendingPathComponent("api/tags")),
                                                 timeout: 10, transport: transport)
        guard status == 200 else { throw .processFailed(exitCode: Int32(status), stderr: String(decoding: data, as: UTF8.self)) }
        return Self.parseModels(data)
    }

    static func parseModels(_ data: Data) -> [String] {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let models = json?["models"] as? [[String: Any]] ?? []
        return models.compactMap { $0["name"] as? String }.sorted()
    }

    func checkConnection() async -> ConnectionReport {
        var report = ConnectionReport()
        do {
            let status = try await server.ensureRunning(manualPath: config.manualPath, baseURL: config.baseURL,
                                                        transport: transport)
            report.binaryPath = status.binaryPath
            report.binarySource = status.source
            report.version = status.version
            let installed = try await installedModels()
            let wanted = config.model.contains(":") ? config.model : config.model + ":latest"
            guard installed.contains(wanted) || installed.contains(config.model) else {
                throw AIError.modelNotInstalled(model: config.model)
            }
            let response = try await run(AIRequest(prompt: "Ответь одним словом: готово.",
                                                   systemPrompt: "Отвечай очень кратко.", timeout: 60))
            report.model = response.model
            report.duration = response.duration
        } catch let error as AIError {
            report.error = error
        } catch {
            report.error = .processFailed(exitCode: -1, stderr: error.localizedDescription)
        }
        return report
    }
}
