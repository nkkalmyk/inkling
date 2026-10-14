import Foundation
import Testing
@testable import Inkling

/// Настоящие ответы CLI из этапа 0 (docs/cli-experiments/raw).
enum RawCLI {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/cli-experiments/raw")

    static func output(_ label: String) throws -> ProcessRunner.Output {
        let out = try Data(contentsOf: folder.appendingPathComponent("\(label).out"))
        let err = try Data(contentsOf: folder.appendingPathComponent("\(label).err"))
        let exit = try String(contentsOf: folder.appendingPathComponent("\(label).exit"), encoding: .utf8)
        return ProcessRunner.Output(exitCode: Int32(exit.trimmingCharacters(in: .whitespacesAndNewlines))!,
                                    stdout: out, stderr: err, signal: nil)
    }

    static func synthetic(stdout: String, stderr: String = "", exit: Int32 = 0) -> ProcessRunner.Output {
        ProcessRunner.Output(exitCode: exit, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), signal: nil)
    }
}

@Suite("Claude: команда и окружение")
struct ClaudeCommandTests {
    @Test func argumentsMatchCLINotes() {
        let args = ClaudeCodeEngine.arguments(model: "sonnet", systemPrompt: "SYS", format: .text)
        #expect(args == ["-p", "--output-format", "json", "--model", "sonnet", "--system-prompt", "SYS",
                         "--tools", "Read", "--safe-mode", "--restricted", "--strict-mcp-config", "--setting-sources=",
                         "--permission-prompts", "none", "--no-session-persistence"])
    }

    @Test func schemaAddsFlag() {
        let args = ClaudeCodeEngine.arguments(model: "opus", systemPrompt: "S", format: .json(schema: #"{"type":"object"}"#))
        #expect(Array(args.suffix(2)) == ["--json-schema", #"{"type":"object"}"#])
        #expect(!ClaudeCodeEngine.arguments(model: "opus", systemPrompt: "S", format: .json(schema: nil)).contains("--json-schema"))
    }

    @Test func environmentDropsClaudeSessionVariablesAndExtendsPath() {
        let env = ClaudeCodeEngine.environment(
            base: ["HOME": "/Users/x", "PATH": "/usr/bin:/custom", "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "sdk",
                   "ANTHROPIC_BASE_URL": "http://x", "CLAUDE_AGENT_SDK_VERSION": "1", "LANG": "ru_RU.UTF-8"],
            extraPath: ["/Users/x/.local/bin", "/usr/bin"])
        #expect(env["HOME"] == "/Users/x" && env["LANG"] == "ru_RU.UTF-8")
        #expect(env.keys.allSatisfy { !$0.hasPrefix("CLAUDE") && !$0.hasPrefix("ANTHROPIC") })
        #expect(env["PATH"] == "/Users/x/.local/bin:/usr/bin:/custom:/bin:/usr/sbin:/sbin")
    }
}

@Suite("Claude: разбор ответа")
struct ClaudeParsingTests {
    private func parse(_ output: ProcessRunner.Output, _ format: AIRequest.Format = .text) -> Result<AIResponse, AIError> {
        ClaudeCodeEngine.parse(output, format: format, requestedModel: "sonnet", duration: 1)
    }

    @Test func realSuccess() throws {
        let response = try parse(try RawCLI.output("claude-sysprompt")).get()
        #expect(response.text.contains(#"\ce{2H2 + O2 -> 2H2O}"#))
        #expect(response.model == "claude-sonnet-5-5")
        #expect(response.engine == .claude)
    }

    @Test func realStructuredOutput() throws {
        let response = try parse(try RawCLI.output("claude-schema"), .json(schema: "{}")).get()
        let data = try #require(response.json)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((json["summary"] as? [String])?.count == 2)
        #expect((json["flashcards"] as? [[String: Any]])?.count == 2)
    }

    @Test func realUnknownModel() throws {
        guard case .failure(let error) = parse(try RawCLI.output("claude-badmodel")) else {
            Issue.record("Ожидалась ошибка")
            return
        }
        #expect(error.isModelUnavailable)
        #expect(!error.isRetryable)
        #expect(error.userMessage.contains("модель недоступна"))
        #expect(error.details.contains("unrecognized_model"))
    }

    @Test func realNotLoggedIn() throws {
        guard case .failure(.notAuthenticated(let details)) = parse(try RawCLI.output("claude-noauth")) else {
            Issue.record("Ожидалась notAuthenticated")
            return
        }
        #expect(details.contains("Not logged in"))
    }

    @Test func realNodeMissingIsBinaryNotFound() throws {
        guard case .failure(.binaryNotFound) = parse(try RawCLI.output("gemini-nonode")) else {
            Issue.record("Ожидалась binaryNotFound")
            return
        }
    }

    @Test func unknownFlag() {
        let result = parse(RawCLI.synthetic(stdout: "", stderr: "error: unknown option '--nope'", exit: 1))
        #expect(result == .failure(.processFailed(exitCode: 1, stderr: "error: unknown option '--nope'")))
    }

    @Test func garbageAroundJSON() throws {
        let json = #"{"type":"result","is_error":false,"result":"Ответ","modelUsage":{"claude-x":{"outputTokens":3}}}"#
        let response = try parse(RawCLI.synthetic(stdout: "Обновление доступно\n\(json)\n\nспасибо")).get()
        #expect(response.text == "Ответ" && response.model == "claude-x")
    }

    @Test func nonJSONSuccessIsInvalidOutput() {
        guard case .failure(.invalidOutput) = parse(RawCLI.synthetic(stdout: "просто текст")) else {
            Issue.record("Ожидалась invalidOutput")
            return
        }
    }

    @Test func emptyResultIsInvalidOutput() {
        guard case .failure(.invalidOutput) = parse(RawCLI.synthetic(stdout: #"{"is_error":false,"result":"  \n"}"#)) else {
            Issue.record("Ожидалась invalidOutput")
            return
        }
    }

    @Test func jsonFormatExtractsFromFencedText() throws {
        let stdout = #"{"is_error":false,"result":"Вот:\n```json\n{\"a\": 1}\n```"}"#
        let response = try parse(RawCLI.synthetic(stdout: stdout), .json(schema: nil)).get()
        let data = try #require(response.json)
        #expect(String(decoding: data, as: UTF8.self) == #"{"a": 1}"#)
    }

    @Test func jsonFormatWithoutJSONIsInvalid() {
        let stdout = #"{"is_error":false,"result":"Не могу"}"#
        guard case .failure(.invalidOutput) = parse(RawCLI.synthetic(stdout: stdout), .json(schema: nil)) else {
            Issue.record("Ожидалась invalidOutput")
            return
        }
    }

    @Test func rateLimitFromResult() throws {
        let stdout = #"{"is_error":true,"result":"You've hit your limit · resets 3pm (Europe/Moscow)","api_error_status":null}"#
        guard case .failure(.rateLimited(let resetAt, let details)) = parse(RawCLI.synthetic(stdout: stdout, exit: 1)) else {
            Issue.record("Ожидалась rateLimited")
            return
        }
        #expect(resetAt != nil)
        #expect(details.contains("hit your limit"))
    }

    @Test func rateLimitFrom429() {
        let stdout = #"{"is_error":true,"result":"API Error","api_error_status":429}"#
        guard case .failure(.rateLimited(nil, _)) = parse(RawCLI.synthetic(stdout: stdout, exit: 1)) else {
            Issue.record("Ожидалась rateLimited без времени")
            return
        }
    }

    @Test func isErrorWithZeroExitIsStillError() {
        let stdout = #"{"is_error":true,"result":"Something broke"}"#
        #expect(parse(RawCLI.synthetic(stdout: stdout)) == .failure(.processFailed(exitCode: 1, stderr: "Something broke")))
    }
}

@Suite("Лимит подписки")
struct RateLimitTests {
    @Test(arguments: [
        "Claude AI usage limit reached|1760000000",
        "You've hit your limit · resets 3pm",
        "You’ve hit your fast limit",
        "You've reached your Fable limit.",
        "You're out of extra usage",
        #"{"type":"error","error":{"type":"rate_limit_error","message":"…"}}"#,
        "Error: 429 Too Many Requests",
        "RESOURCE_EXHAUSTED: Quota exceeded for quota metric",
        "Rate limited, please slow down",
    ])
    func detects(_ text: String) {
        #expect(RateLimitDetector.isRateLimited(text))
    }

    @Test(arguments: [
        "Not logged in · Please run /login",
        "There's an issue with the selected model",
        "Ответ модели: лимит функции равен 1",
        "error 4290 in module",
    ])
    func ignores(_ text: String) {
        #expect(!RateLimitDetector.isRateLimited(text))
    }

    private let moscow = TimeZone(identifier: "Europe/Moscow")!
    /// 2026-10-14 10:00 по Москве.
    private let now = ISO8601DateFormatter().date(from: "2026-10-14T07:00:00Z")!

    private func iso(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    @Test func resetTimeToday() {
        #expect(RateLimitDetector.resetDate(in: "limit · resets 3pm", now: now, timeZone: moscow) == iso("2026-10-14T12:00:00Z"))
        #expect(RateLimitDetector.resetDate(in: "resets at 15:30", now: now, timeZone: moscow) == iso("2026-10-14T12:30:00Z"))
    }

    @Test func resetTimeTomorrowWhenPassed() {
        #expect(RateLimitDetector.resetDate(in: "resets 9am", now: now, timeZone: moscow) == iso("2026-10-15T06:00:00Z"))
    }

    @Test func resetWithExplicitZone() {
        #expect(RateLimitDetector.resetDate(in: "resets 3pm (UTC)", now: now, timeZone: moscow) == iso("2026-10-14T15:00:00Z"))
    }

    @Test func resetWithMonthDay() {
        #expect(RateLimitDetector.resetDate(in: "resets Oct 16, 12am", now: now, timeZone: moscow) == iso("2026-10-15T21:00:00Z"))
    }

    @Test func resetISO() {
        #expect(RateLimitDetector.resetDate(in: "resets at 2026-10-15T12:00:00Z", now: now) == iso("2026-10-15T12:00:00Z"))
    }

    @Test(arguments: ["usage limit reached", "resets soon", "resets 25:00", "resets at noon"])
    func unknownReset(_ text: String) {
        #expect(RateLimitDetector.resetDate(in: text, now: now, timeZone: moscow) == nil)
    }

    @Test func messageShowsResetTime() {
        let error = AIError.rateLimited(resetAt: iso("2026-10-14T12:00:00Z"), details: "")
        #expect(error.userMessage.hasPrefix("Исчерпан лимит подписки. Он восстановится в"))
        #expect(AIError.rateLimited(resetAt: nil, details: "").userMessage == "Исчерпан лимит подписки. Попробуйте позже.")
    }
}

@Suite("JSONExtractor")
struct JSONExtractorTests {
    private func extract(_ text: String) -> String? {
        JSONExtractor.object(in: text).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func plainObject() { #expect(extract(#"  {"a":1}  "#) == #"{"a":1}"#) }

    @Test func fencedBlock() {
        #expect(extract("Вот JSON:\n```json\n{\"a\": [1, 2]}\n```\nГотово.") == #"{"a": [1, 2]}"#)
        #expect(extract("```\n{\"b\": true}\n```") == #"{"b": true}"#)
    }

    @Test func wrappedInText() {
        #expect(extract(#"Конечно! {"q": "скобка } в строке", "n": {"x": 1}} Надеюсь, помог."#)
            == #"{"q": "скобка } в строке", "n": {"x": 1}}"#)
    }

    @Test func skipsBrokenCandidate() {
        #expect(extract(#"{не json} и потом {"ok": 1}"#) == #"{"ok": 1}"#)
    }

    @Test func noObject() {
        #expect(extract("[1, 2, 3]") == nil)
        #expect(extract("ничего") == nil)
        #expect(extract(#"{"обрыв": "#) == nil)
    }
}

@Suite("Ошибки")
struct AIErrorTests {
    @Test func retryPolicy() {
        #expect(AIError.timeout.isRetryable)
        #expect(AIError.invalidOutput("").isRetryable)
        #expect(AIError.processFailed(exitCode: 1, stderr: "boom").isRetryable)
        #expect(!AIError.notAuthenticated("").isRetryable)
        #expect(!AIError.binaryNotFound("").isRetryable)
        #expect(!AIError.cancelled.isRetryable)
        #expect(!AIError.rateLimited(resetAt: nil, details: "").isRetryable)
    }

    @Test func everyErrorHasRussianMessage() {
        let errors: [AIError] = [.binaryNotFound(""), .notAuthenticated(""), .rateLimited(resetAt: nil, details: ""),
                                 .timeout, .cancelled, .invalidOutput(""), .processFailed(exitCode: 2, stderr: ""),
                                 .ollamaUnavailable(""), .modelNotInstalled(model: "m")]
        for error in errors {
            #expect(error.userMessage.range(of: "[А-Яа-яЁё]", options: .regularExpression) != nil)
        }
    }
}
