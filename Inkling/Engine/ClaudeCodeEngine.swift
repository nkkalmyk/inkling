import Foundation

/// Claude Code в headless-режиме (`claude -p`). Команда и изоляция — из docs/cli-notes.md, раздел «Итоговая команда».
struct ClaudeCodeEngine: AIEngine {
    struct Config: Sendable {
        var manualPath: String?
        var model: String = "sonnet"
        /// Оставлять временную папку запуска при ошибке (настройка для отладки).
        var keepTempOnError = false
    }

    let id = EngineID.claude
    var config: Config
    var locator: BinaryLocator = .live
    var tempRoot: URL = FileManager.default.temporaryDirectory

    // MARK: Команда

    /// Аргументы после пути к бинарнику. Промпт передаётся через stdin.
    static func arguments(model: String, systemPrompt: String, format: AIRequest.Format) -> [String] {
        var args = [
            "-p",
            "--output-format", "json",
            "--model", model,
            "--system-prompt", systemPrompt,
            "--tools", "Read",
            "--safe-mode", "--restricted", "--strict-mcp-config", "--setting-sources=",
            "--permission-prompts", "none",
            "--no-session-persistence",
        ]
        if case .json(let schema?) = format {
            args += ["--json-schema", schema]
        }
        return args
    }

    /// Окружение процесса: окружение приложения без переменных, которые меняют вход или поведение Claude Code
    /// (например, если приложение запущено из сессии Claude Code), плюс нужные каталоги в PATH.
    static func environment(base: [String: String], extraPath: [String]) -> [String: String] {
        let blockedPrefixes = ["CLAUDECODE", "CLAUDE_CODE_", "CLAUDE_AGENT_SDK", "ANTHROPIC_"]
        // Чужие секреты окружения Claude Code не нужны: вход идёт через его собственное хранилище.
        let secretPrefixes = ["AWS_", "GITHUB_", "GH_", "NPM_TOKEN", "OPENAI_", "GOOGLE_API", "GEMINI_"]
        let secretSuffixes = ["_TOKEN", "_SECRET", "_PASSWORD", "_API_KEY", "_SECRET_KEY"]
        var env = base.filter { key, _ in
            !blockedPrefixes.contains { key.hasPrefix($0) }
                && !secretPrefixes.contains { key.hasPrefix($0) }
                && !secretSuffixes.contains { key.hasSuffix($0) }
        }
        let systemPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let current = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        var path: [String] = []
        for dir in extraPath + current + systemPath where !dir.isEmpty && !path.contains(dir) { path.append(dir) }
        env["PATH"] = path.joined(separator: ":")
        return env
    }

    // MARK: Разбор ответа

    /// Разбирает вывод `claude -p --output-format json`. Успех — только `exit == 0 && is_error == false`.
    static func parse(_ output: ProcessRunner.Output, format: AIRequest.Format, requestedModel: String,
                      duration: TimeInterval) -> Result<AIResponse, AIError> {
        let stderr = output.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = JSONExtractor.object(in: output.stdoutText),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if output.exitCode == 0 {
                return .failure(.invalidOutput("Ответ не в формате JSON:\n" + String(output.stdoutText.prefix(2000))))
            }
            return .failure(classify(message: "", stderr: stderr, apiStatus: nil, exitCode: output.exitCode))
        }

        let resultText = json["result"] as? String ?? ""
        let isError = json["is_error"] as? Bool ?? false
        let apiStatus = json["api_error_status"] as? Int
        if isError || output.exitCode != 0 {
            return .failure(classify(message: resultText, stderr: stderr, apiStatus: apiStatus,
                                     exitCode: output.exitCode == 0 ? 1 : output.exitCode))
        }

        let model = actualModel(json["modelUsage"]) ?? requestedModel
        switch format {
        case .text:
            guard !resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(.invalidOutput("Пустой ответ модели."))
            }
            return .success(AIResponse(text: resultText, json: nil, engine: .claude, model: model, duration: duration))
        case .json(let schema):
            var jsonData: Data?
            if schema != nil, let structured = json["structured_output"], !(structured is NSNull) {
                jsonData = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys])
            }
            jsonData = jsonData ?? JSONExtractor.object(in: resultText)
            guard let jsonData else {
                return .failure(.invalidOutput("В ответе модели нет JSON:\n" + String(resultText.prefix(2000))))
            }
            return .success(AIResponse(text: resultText, json: jsonData, engine: .claude, model: model, duration: duration))
        }
    }

    static func classify(message: String, stderr: String, apiStatus: Int?, exitCode: Int32) -> AIError {
        let combined = (message == stderr ? [message] : [message, stderr]).filter { !$0.isEmpty }.joined(separator: "\n")
        let lower = combined.lowercased()
        if exitCode == 127 || lower.contains("no such file or directory") && lower.contains("env:") {
            return .binaryNotFound(combined)
        }
        if lower.contains("not logged in") || lower.contains("please run /login") || lower.contains("invalid api key")
            || lower.contains("authentication_failed") || lower.contains("oauth token") {
            return .notAuthenticated(combined)
        }
        if apiStatus == 429 || RateLimitDetector.isRateLimited(combined) {
            return .rateLimited(resetAt: RateLimitDetector.resetDate(in: combined), details: combined)
        }
        return .processFailed(exitCode: exitCode, stderr: combined)
    }

    /// Модель, которая реально ответила: ключ `modelUsage` с наибольшим числом выходных токенов.
    private static func actualModel(_ usage: Any?) -> String? {
        guard let usage = usage as? [String: Any], !usage.isEmpty else { return nil }
        return usage.max { lhs, rhs in
            let l = (lhs.value as? [String: Any])?["outputTokens"] as? Int ?? 0
            let r = (rhs.value as? [String: Any])?["outputTokens"] as? Int ?? 0
            return l < r
        }?.key
    }

    // MARK: Запуск

    func run(_ request: AIRequest) async throws(AIError) -> AIResponse {
        let located: BinaryLocator.Located
        do {
            located = try await locator.locate("claude", manualPath: config.manualPath)
        } catch {
            throw .binaryNotFound(error.message)
        }

        let workdir = tempRoot.appendingPathComponent("Inkling-run-\(UUID().uuidString)", isDirectory: true)
        var failed = true
        defer {
            if !(failed && config.keepTempOnError) { try? FileManager.default.removeItem(at: workdir) }
        }
        do {
            try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
            for image in request.images {
                try FileManager.default.copyItem(at: image, to: workdir.appendingPathComponent(image.lastPathComponent))
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
                arguments: Self.arguments(model: model, systemPrompt: request.systemPrompt, format: request.format),
                environment: Self.environment(base: ProcessInfo.processInfo.environment, extraPath: located.extraPath),
                workingDirectory: workdir.path, stdin: Data(request.prompt.utf8), timeout: request.timeout)
        } catch {
            switch error {
            case .launchFailed(let message): throw .binaryNotFound(message)
            case .timedOut: throw .timeout
            case .cancelled: throw .cancelled
            }
        }
        let result = Self.parse(output, format: request.format, requestedModel: model,
                                duration: Date().timeIntervalSince(started))
        switch result {
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
            located = try await locator.locate("claude", manualPath: config.manualPath)
        } catch {
            report.error = .binaryNotFound(error.message)
            return report
        }
        report.binaryPath = located.path
        report.binarySource = located.source.rawValue

        let env = Self.environment(base: ProcessInfo.processInfo.environment, extraPath: located.extraPath)
        if let version = try? await ProcessRunner.run(executable: located.path, arguments: ["--version"], environment: env,
                                                      workingDirectory: NSTemporaryDirectory(), timeout: 20) {
            report.version = version.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        do {
            let response = try await run(AIRequest(prompt: "Ответь одним словом: готово.",
                                                   systemPrompt: "Отвечай очень кратко.", timeout: 90))
            report.model = response.model
            report.duration = response.duration
        } catch {
            report.error = error
        }
        return report
    }
}
