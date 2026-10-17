import Foundation

/// Codex CLI в неинтерактивном режиме (`codex exec`), вход через подписку ChatGPT.
/// Команда и формат событий — docs/cli-notes.md, раздел «Codex CLI».
///
/// **Не проверен вживую**: у автора нет подписки ChatGPT. Флаги сверены по `codex exec --help` и пробному запуску без входа,
/// формат успешного ответа (`agent_message`) взят из документации OpenAI. Движок отмечен в интерфейсе как непроверенный.
struct CodexEngine: AIEngine {
    struct Config: Sendable {
        var manualPath: String?
        /// Пусто — модель выбирает сам Codex: набор моделей зависит от тарифа, неизвестное имя Codex лишь предупреждает.
        var model: String = ""
        var keepTempOnError = false
    }

    let id = EngineID.codex
    var config: Config
    var locator: BinaryLocator = .live
    var tempRoot: URL = FileManager.default.temporaryDirectory

    static let lastMessageFileName = "last-message.txt"

    // MARK: Команда

    /// Аргументы после пути к бинарнику. Промпт идёт через stdin без `-`: `-i` принимает несколько значений и съел бы его.
    static func arguments(model: String, workdir: String, images: [String]) -> [String] {
        var args = [
            "exec", "--json", "--skip-git-repo-check", "--ephemeral",
            "--ignore-user-config", "--ignore-rules",
            "-s", "read-only",
            "-C", workdir,
            "-o", lastMessageFileName,
        ]
        if !model.isEmpty { args += ["-m", model] }
        for image in images { args += ["-i", image] }
        return args
    }

    /// Окружение: без чужих секретов, в том числе `OPENAI_*` и `CODEX_API_KEY`, иначе Codex мог бы уйти с подписки на ключ API.
    /// `CODEX_HOME` остаётся: там хранится вход.
    static func environment(base: [String: String], extraPath: [String]) -> [String: String] {
        ClaudeCodeEngine.environment(base: base, extraPath: extraPath)
    }

    /// У `codex exec` нет флага системного промпта: он идёт первым блоком. Схема JSON, если есть, передаётся текстом
    /// (`--output-schema` у OpenAI требует строгую схему, а наши схемы нестрогие).
    static func composePrompt(_ request: AIRequest) -> String {
        var parts = ["Инструкции:\n" + request.systemPrompt]
        if !request.images.isEmpty {
            let names = request.images.map(\.lastPathComponent).joined(separator: ", ")
            parts.append("Изображения приложены к запросу (\(names)); читать файлы командами не нужно.")
        }
        parts.append(request.prompt)
        if case .json(let schema?) = request.format {
            parts.append("Ответ — строго один JSON-объект по этой схеме, без пояснений и без блока кода:\n" + schema)
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: Разбор ответа

    struct Events: Equatable {
        var agentMessages: [String] = []
        var completed = false
        /// Сообщение `turn.failed` или последнее фатальное `error`.
        var failure: String?
    }

    /// Разбирает JSONL. События `error` с «Reconnecting…» — повторы подключения, сами по себе не фатальны.
    static func parseEvents(_ stdout: String) -> Events {
        var events = Events()
        var lastError: String?
        for line in stdout.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            switch type {
            case "item.completed":
                if let item = object["item"] as? [String: Any], item["type"] as? String == "agent_message",
                   let text = item["text"] as? String {
                    events.agentMessages.append(text)
                }
            case "turn.completed":
                events.completed = true
            case "turn.failed":
                if let message = (object["error"] as? [String: Any])?["message"] as? String { events.failure = message }
                else { events.failure = events.failure ?? "turn.failed" }
            case "error":
                if let message = object["message"] as? String, !message.hasPrefix("Reconnecting") { lastError = message }
            default:
                break
            }
        }
        if events.failure == nil, !events.completed, let lastError { events.failure = lastError }
        return events
    }

    /// Успех — `exit == 0`, нет `turn.failed` и есть текст последнего сообщения (файл `-o` важнее событий).
    static func parse(_ output: ProcessRunner.Output, lastMessage: String?, format: AIRequest.Format,
                      requestedModel: String, duration: TimeInterval) -> Result<AIResponse, AIError> {
        let events = parseEvents(output.stdoutText)
        let stderr = output.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.exitCode != 0 || events.failure != nil {
            return .failure(classify(message: events.failure ?? "", stderr: stderr,
                                     exitCode: output.exitCode == 0 ? 1 : output.exitCode))
        }
        let fromFile = lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = fromFile.isEmpty ? (events.agentMessages.last ?? "") : fromFile
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.invalidOutput("Пустой ответ Codex."))
        }
        let model = requestedModel.isEmpty ? "codex" : requestedModel
        switch format {
        case .text:
            return .success(AIResponse(text: text, json: nil, engine: .codex, model: model, duration: duration))
        case .json:
            guard let json = JSONExtractor.object(in: text) else {
                return .failure(.invalidOutput("В ответе Codex нет JSON:\n" + String(text.prefix(2000))))
            }
            return .success(AIResponse(text: text, json: json, engine: .codex, model: model, duration: duration))
        }
    }

    static func classify(message: String, stderr: String, exitCode: Int32) -> AIError {
        let combined = (message == stderr ? [message] : [message, stderr]).filter { !$0.isEmpty }.joined(separator: "\n")
        let lower = combined.lowercased()
        if exitCode == 127 || lower.contains("command not found") || lower.contains("no such file or directory") && lower.contains("env:") {
            return .codexUnavailable(combined)
        }
        if lower.contains("not logged in") || lower.contains("401 unauthorized") || lower.contains("missing bearer")
            || lower.contains("codex login") || lower.contains("please log in") || lower.contains("sign in again") {
            return .codexNotAuthenticated(combined)
        }
        if RateLimitDetector.isRateLimited(combined) || lower.contains("usage limit") {
            return .rateLimited(resetAt: RateLimitDetector.resetDate(in: combined), details: combined)
        }
        return .processFailed(exitCode: exitCode, stderr: combined)
    }

    // MARK: Запуск

    func run(_ request: AIRequest) async throws(AIError) -> AIResponse {
        let located: BinaryLocator.Located
        do {
            located = try await locator.locate("codex", manualPath: config.manualPath)
        } catch {
            throw .codexUnavailable(error.message)
        }

        let workdir = tempRoot.appendingPathComponent("Inkling-run-\(UUID().uuidString)", isDirectory: true)
        var failed = true
        defer {
            if !(failed && config.keepTempOnError) { try? FileManager.default.removeItem(at: workdir) }
        }
        var imageNames: [String] = []
        do {
            try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
            for image in request.images {
                try FileManager.default.copyItem(at: image, to: workdir.appendingPathComponent(image.lastPathComponent))
                imageNames.append(image.lastPathComponent)
            }
        } catch {
            throw .processFailed(exitCode: -1, stderr: "Не удалось подготовить временную папку: \(error.localizedDescription)")
        }

        let model = request.model ?? config.model
        let started = Date()
        let output: ProcessRunner.Output
        do {
            output = try await ProcessRunner.run(
                executable: located.path,
                arguments: Self.arguments(model: model, workdir: workdir.path, images: imageNames),
                environment: Self.environment(base: ProcessInfo.processInfo.environment, extraPath: located.extraPath),
                workingDirectory: workdir.path, stdin: Data(Self.composePrompt(request).utf8), timeout: request.timeout)
        } catch {
            switch error {
            case .launchFailed(let message): throw .codexUnavailable(message)
            case .timedOut: throw .timeout
            case .cancelled: throw .cancelled
            }
        }
        let lastMessage = try? String(contentsOf: workdir.appendingPathComponent(Self.lastMessageFileName), encoding: .utf8)
        switch Self.parse(output, lastMessage: lastMessage, format: request.format, requestedModel: model,
                          duration: Date().timeIntervalSince(started)) {
        case .success(let response):
            failed = false
            return response
        case .failure(let error):
            throw error
        }
    }

    // MARK: Проверка подключения

    func checkConnection() async -> ConnectionReport {
        var report = ConnectionReport()
        let located: BinaryLocator.Located
        do {
            located = try await locator.locate("codex", manualPath: config.manualPath)
        } catch {
            report.error = .codexUnavailable(error.message)
            return report
        }
        report.binaryPath = located.path
        report.binarySource = located.source.rawValue

        let env = Self.environment(base: ProcessInfo.processInfo.environment, extraPath: located.extraPath)
        if let version = try? await ProcessRunner.run(executable: located.path, arguments: ["--version"], environment: env,
                                                      workingDirectory: NSTemporaryDirectory(), timeout: 20) {
            report.version = version.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Быстрая проверка входа без запроса к модели: без входа тестовый запрос ждал бы около 30 с повторов.
        if let status = try? await ProcessRunner.run(executable: located.path, arguments: ["login", "status"], environment: env,
                                                      workingDirectory: NSTemporaryDirectory(), timeout: 20),
           status.exitCode != 0 {
            let text = (status.stdoutText + status.stderrText).trimmingCharacters(in: .whitespacesAndNewlines)
            report.error = .codexNotAuthenticated(text)
            return report
        }

        do {
            let response = try await run(AIRequest(prompt: "Ответь одним словом: готово.",
                                                   systemPrompt: "Отвечай очень кратко.", timeout: 120))
            report.model = response.model
            report.duration = response.duration
        } catch {
            report.error = error
        }
        return report
    }
}
