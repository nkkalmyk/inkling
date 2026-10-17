import Foundation
import Testing
@testable import Inkling

/// Codex не проверен вживую (нет подписки): тесты идут на настоящем выводе без входа (`codex-noauth`)
/// и на синтетических ответах, собранных по документации OpenAI.
@Suite("Codex: команда, разбор, ошибки")
struct CodexEngineTests {
    private static func jsonl(_ events: [String]) -> String { events.joined(separator: "\n") + "\n" }

    private static let success = jsonl([
        #"{"type":"thread.started","thread_id":"t1"}"#,
        #"{"type":"turn.started"}"#,
        #"{"type":"item.completed","item":{"id":"item_0","type":"reasoning","text":"думаю"}}"#,
        #"{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"Первый ответ"}}"#,
        #"{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"Итоговый ответ"}}"#,
        #"{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}}"#,
    ])

    // MARK: Команда

    @Test func argumentsMatchCLINotes() {
        let args = CodexEngine.arguments(model: "", workdir: "/tmp/w", images: ["a.jpg", "b.jpg"])
        #expect(args == ["exec", "--json", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules",
                         "-s", "read-only", "-C", "/tmp/w", "-o", "last-message.txt", "-i", "a.jpg", "-i", "b.jpg"])
        // Промпт идёт через stdin: `-` после -i съелся бы как имя файла.
        #expect(!args.contains("-"))
        #expect(!args.contains("--output-schema"))
    }

    @Test func modelFlagOnlyWhenChosen() {
        #expect(!CodexEngine.arguments(model: "", workdir: "/w", images: []).contains("-m"))
        let args = CodexEngine.arguments(model: "gpt-x", workdir: "/w", images: [])
        #expect(args.contains("-m"))
        #expect(args[args.firstIndex(of: "-m")! + 1] == "gpt-x")
    }

    @Test func promptCarriesSystemPromptImagesAndSchemaAsText() {
        var request = AIRequest(prompt: "ПРОМПТ", systemPrompt: "СИСТЕМА", images: [URL(fileURLWithPath: "/x/page.jpg")],
                                format: .json(schema: #"{"type":"object"}"#))
        let text = CodexEngine.composePrompt(request)
        #expect(text.hasPrefix("Инструкции:\nСИСТЕМА"))
        #expect(text.contains("page.jpg"))
        #expect(text.contains("ПРОМПТ"))
        #expect(text.hasSuffix(#"{"type":"object"}"#))
        request.format = .text
        request.images = []
        #expect(!CodexEngine.composePrompt(request).contains("JSON"))
    }

    @Test func environmentDropsApiKeysAndKeepsCodexHome() {
        let base = ["HOME": "/Users/x", "CODEX_HOME": "/Users/x/.codex", "OPENAI_API_KEY": "k", "CODEX_API_KEY": "k2",
                    "GITHUB_TOKEN": "t", "PATH": "/usr/bin"]
        let env = CodexEngine.environment(base: base, extraPath: ["/opt/homebrew/bin"])
        #expect(env["CODEX_HOME"] == "/Users/x/.codex")
        #expect(env["OPENAI_API_KEY"] == nil)
        #expect(env["CODEX_API_KEY"] == nil)
        #expect(env["GITHUB_TOKEN"] == nil)
        #expect(env["PATH"]?.hasPrefix("/opt/homebrew/bin") == true)
    }

    // MARK: Разбор успешного ответа

    @Test func successUsesLastMessageFileOverEvents() throws {
        let output = RawCLI.synthetic(stdout: Self.success)
        let fromFile = try CodexEngine.parse(output, lastMessage: "Из файла\n", format: .text, requestedModel: "", duration: 1).get()
        #expect(fromFile.text == "Из файла\n".trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(fromFile.engine == .codex)
        #expect(fromFile.model == "codex")
        let fromEvents = try CodexEngine.parse(output, lastMessage: nil, format: .text, requestedModel: "gpt-x", duration: 1).get()
        #expect(fromEvents.text == "Итоговый ответ")
        #expect(fromEvents.model == "gpt-x")
    }

    @Test func jsonFormatExtractsObjectFromFencedAnswer() throws {
        let events = Self.jsonl([#"{"type":"item.completed","item":{"type":"agent_message","text":"```json\n{\"a\": 1}\n```"}}"#,
                                 #"{"type":"turn.completed"}"#])
        let response = try CodexEngine.parse(RawCLI.synthetic(stdout: events), lastMessage: nil, format: .json(schema: nil),
                                             requestedModel: "", duration: 1).get()
        let data = try #require(response.json)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Int])
        #expect(object == ["a": 1])
        let broken = CodexEngine.parse(RawCLI.synthetic(stdout: Self.success), lastMessage: nil, format: .json(schema: nil),
                                       requestedModel: "", duration: 1)
        #expect(throws: AIError.self) { try broken.get() }
    }

    @Test func emptyAnswerIsInvalidOutput() {
        let events = Self.jsonl([#"{"type":"turn.started"}"#, #"{"type":"turn.completed"}"#])
        let result = CodexEngine.parse(RawCLI.synthetic(stdout: events), lastMessage: "  \n", format: .text,
                                       requestedModel: "", duration: 1)
        if case .failure(.invalidOutput) = result {} else { Issue.record("ожидалась invalidOutput: \(result)") }
    }

    // MARK: Ошибки

    @Test func realOutputWithoutLoginIsNotAuthenticated() throws {
        let output = try RawCLI.output("codex-noauth")
        let events = CodexEngine.parseEvents(output.stdoutText)
        #expect(!events.completed)
        #expect(events.failure?.contains("401 Unauthorized") == true)
        #expect(events.agentMessages.isEmpty)
        let result = CodexEngine.parse(output, lastMessage: nil, format: .text, requestedModel: "", duration: 30)
        guard case .failure(.codexNotAuthenticated(let details)) = result else {
            Issue.record("ожидалась codexNotAuthenticated: \(result)")
            return
        }
        #expect(details.contains("401"))
    }

    @Test func reconnectingNoticesAreNotFatalWhenTurnCompletes() {
        let events = Self.jsonl([
            #"{"type":"error","message":"Reconnecting... 1/5 (timeout)"}"#,
            #"{"type":"item.completed","item":{"type":"agent_message","text":"ок"}}"#,
            #"{"type":"turn.completed"}"#,
        ])
        let parsed = CodexEngine.parseEvents(events)
        #expect(parsed.failure == nil)
        #expect(parsed.completed)
        #expect((try? CodexEngine.parse(RawCLI.synthetic(stdout: events), lastMessage: nil, format: .text,
                                        requestedModel: "", duration: 1).get().text) == "ок")
    }

    @Test func classifiesLimitMissingBinaryAndOthers() {
        let limit = CodexEngine.classify(message: "You've hit your usage limit. Try again later.", stderr: "", exitCode: 1)
        if case .rateLimited = limit {} else { Issue.record("лимит: \(limit)") }
        let missing = CodexEngine.classify(message: "", stderr: "zsh: command not found: codex", exitCode: 127)
        if case .codexUnavailable = missing {} else { Issue.record("нет бинарника: \(missing)") }
        let login = CodexEngine.classify(message: "Not logged in", stderr: "", exitCode: 1)
        if case .codexNotAuthenticated = login {} else { Issue.record("нет входа: \(login)") }
        let other = CodexEngine.classify(message: "something odd", stderr: "", exitCode: 2)
        if case .processFailed(let code, _) = other { #expect(code == 2) } else { Issue.record("прочее: \(other)") }
    }

    @Test func failedTurnWithZeroExitStillFails() {
        let events = Self.jsonl([#"{"type":"turn.failed","error":{"message":"boom"}}"#])
        let result = CodexEngine.parse(RawCLI.synthetic(stdout: events), lastMessage: "текст", format: .text,
                                       requestedModel: "", duration: 1)
        if case .failure(.processFailed) = result {} else { Issue.record("ожидалась ошибка: \(result)") }
    }

    // MARK: Настройки и маршрутизация

    @MainActor
    @Test func codexOnlyModeRoutesToCodex() {
        let routing = EngineCenter.routing(mode: .codexOnly, primary: .claude, fallback: .ollama)
        #expect(routing.primary == .codex)
        #expect(routing.fallback == nil)
        let auto = EngineCenter.routing(mode: .auto, primary: .codex, fallback: .claude)
        #expect(auto.primary == .codex)
        #expect(auto.fallback == .claude)
    }

    @Test func codexIsFlaggedAsUnverifiedCloudEngine() {
        #expect(EngineID.codex.isUnverified)
        #expect(EngineID.codex.isCloud)
        #expect(!EngineID.claude.isUnverified)
        #expect(!EngineID.ollama.isCloud)
        #expect(EngineID.codex.needsReview == false)
    }

    @Test func userMessagesMentionCodex() {
        #expect(AIError.codexUnavailable("x").userMessage.contains("Codex"))
        #expect(AIError.codexNotAuthenticated("x").userMessage.contains("codex login"))
    }
}
