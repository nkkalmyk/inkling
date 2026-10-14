import Darwin
import Foundation
import Testing
@testable import Inkling

@Suite("ProcessRunner")
struct ProcessRunnerTests {
    private func sh(_ script: String, stdin: Data? = nil, timeout: TimeInterval = 10, grace: TimeInterval = 3,
                    env: [String: String] = ["PATH": "/usr/bin:/bin"], cwd: String = "/") async throws(ProcessRunner.Failure)
        -> ProcessRunner.Output {
        try await ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", script], environment: env,
                                    workingDirectory: cwd, stdin: stdin, timeout: timeout, killGrace: grace)
    }

    @Test func capturesOutputAndExitCode() async throws {
        let output = try await sh("echo привет; echo ошибка >&2; exit 3")
        #expect(output.exitCode == 3)
        #expect(output.stdoutText == "привет\n")
        #expect(output.stderrText == "ошибка\n")
        #expect(output.signal == nil)
    }

    @Test func passesStdinEnvironmentAndDirectory() async throws {
        let dir = try TempDir()
        let output = try await sh(#"cat; echo "$INKLING_X"; pwd"#, stdin: Data("из stdin\n".utf8),
                                  env: ["PATH": "/usr/bin:/bin", "INKLING_X": "значение"], cwd: dir.url.path)
        let lines = output.stdoutText.split(separator: "\n").map(String.init)
        #expect(lines[0] == "из stdin")
        #expect(lines[1] == "значение")
        #expect(lines[2].hasSuffix(dir.url.lastPathComponent))
    }

    @Test func readsLargeOutputFully() async throws {
        let output = try await sh("head -c 3000000 /dev/zero | tr '\\0' 'x'")
        #expect(output.stdout.count == 3_000_000)
    }

    @Test func missingExecutable() async {
        await #expect(throws: ProcessRunner.Failure.self) {
            try await ProcessRunner.run(executable: "/nonexistent/claude", arguments: [], environment: [:],
                                        workingDirectory: "/", timeout: 5)
        }
    }

    @Test func timeoutKillsWholeGroup() async throws {
        let dir = try TempDir()
        let pidFile = dir.url.appendingPathComponent("child.pid").path
        let started = Date()
        do {
            _ = try await sh("sleep 60 & echo $! > '\(pidFile)'; wait", timeout: 0.5)
            Issue.record("Ожидался таймаут")
        } catch {
            guard case .timedOut = error else { Issue.record("Ожидался timedOut, получено \(error)"); return }
        }
        #expect(Date().timeIntervalSince(started) < 5)
        let pidText = try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let childPID = try #require(pid_t(pidText))
        try await Task.sleep(for: .milliseconds(200))
        #expect(kill(childPID, 0) != 0, "Внук должен быть убит вместе с группой")
    }

    @Test func ignoredTermEscalatesToKill() async throws {
        let started = Date()
        do {
            _ = try await sh("trap '' TERM; sleep 60", timeout: 0.3, grace: 0.5)
            Issue.record("Ожидался таймаут")
        } catch {
            guard case .timedOut(let output) = error else { Issue.record("Ожидался timedOut"); return }
            #expect(output.signal == SIGKILL)
        }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func cancellationStopsProcess() async throws {
        let task = Task { () async throws -> ProcessRunner.Output in
            try await sh("sleep 60", timeout: 120)
        }
        try await Task.sleep(for: .milliseconds(300))
        let started = Date()
        task.cancel()
        let result = await task.result
        guard case .failure(let error) = result, case .cancelled = error as? ProcessRunner.Failure else {
            Issue.record("Ожидался cancelled, получено \(result)")
            return
        }
        #expect(Date().timeIntervalSince(started) < 5)
    }
}

@Suite("BinaryLocator")
struct BinaryLocatorTests {
    final class FakeFS: @unchecked Sendable {
        var executables: Set<String> = []
        var directories: [String: [String]] = [:]
        var headers: [String: String] = [:]
        var shell: [String: String] = [:]
    }

    private func locator(_ fs: FakeFS) -> BinaryLocator {
        BinaryLocator(home: "/Users/u",
                      isExecutable: { fs.executables.contains($0) },
                      contentsOfDirectory: { fs.directories[$0] ?? [] },
                      fileHeader: { fs.headers[$0] ?? "\u{CF}\u{FA}\u{ED}\u{FE}" },
                      shellLookup: { fs.shell[$0] })
    }

    @Test func manualPathWins() async throws {
        let fs = FakeFS()
        fs.executables = ["/opt/homebrew/bin/claude", "/custom/claude"]
        let found = try await locator(fs).locate("claude", manualPath: "/custom/claude")
        #expect(found == .init(path: "/custom/claude", source: .manual, extraPath: ["/custom"]))
    }

    @Test func invalidManualPathIsAnError() async {
        let fs = FakeFS()
        fs.executables = ["/opt/homebrew/bin/claude"]
        await #expect(throws: BinaryLocator.Failure.manualPathInvalid("/nope/claude")) {
            try await locator(fs).locate("claude", manualPath: "/nope/claude")
        }
    }

    @Test func knownLocationsInOrder() async throws {
        let fs = FakeFS()
        fs.executables = ["/Users/u/.local/bin/claude", "/usr/local/bin/claude"]
        let found = try await locator(fs).locate("claude", manualPath: "  ")
        #expect(found.path == "/usr/local/bin/claude")
        #expect(found.source == .knownLocation)
    }

    @Test func newestNvmVersionFirst() {
        let fs = FakeFS()
        fs.directories["/Users/u/.nvm/versions/node"] = ["v18.20.0", "v20.9.0", "v20.10.0"]
        let dirs = locator(fs).knownDirectories()
        let nvm = dirs.filter { $0.contains(".nvm") }
        #expect(nvm == ["/Users/u/.nvm/versions/node/v20.10.0/bin", "/Users/u/.nvm/versions/node/v20.9.0/bin",
                        "/Users/u/.nvm/versions/node/v18.20.0/bin"])
        #expect(dirs.first == "/opt/homebrew/bin")
    }

    @Test func shellFallback() async throws {
        let fs = FakeFS()
        fs.executables = ["/weird/place/claude"]
        fs.shell["claude"] = "/weird/place/claude"
        let found = try await locator(fs).locate("claude", manualPath: nil)
        #expect(found.source == .shell && found.path == "/weird/place/claude")
    }

    @Test func nodeScriptGetsNodeDirectoryInPath() async throws {
        let fs = FakeFS()
        fs.executables = ["/Users/u/.npm-global/bin/claude", "/Users/u/.nvm/versions/node/v22.1.0/bin/node"]
        fs.directories["/Users/u/.nvm/versions/node"] = ["v22.1.0"]
        fs.headers["/Users/u/.npm-global/bin/claude"] = "#!/usr/bin/env node\nconsole.log()"
        let found = try await locator(fs).locate("claude", manualPath: nil)
        #expect(found.extraPath == ["/Users/u/.npm-global/bin", "/Users/u/.nvm/versions/node/v22.1.0/bin"])
    }

    @Test func nodeScriptWithoutNode() async {
        let fs = FakeFS()
        fs.executables = ["/opt/homebrew/bin/gemini"]
        fs.headers["/opt/homebrew/bin/gemini"] = "#!/usr/bin/env node\n"
        await #expect(throws: BinaryLocator.Failure.nodeNotFound("/opt/homebrew/bin/gemini")) {
            try await locator(fs).locate("gemini", manualPath: nil)
        }
    }

    @Test func notFound() async {
        await #expect(throws: BinaryLocator.Failure.notFound("claude")) {
            try await locator(FakeFS()).locate("claude", manualPath: nil)
        }
    }

    @Test func shellOutputParsing() {
        let noisy = "Last login: Tue\n\u{1B}]0;title\u{07}oh-my-zsh update\n__INKLING_BEGIN__\n/Users/u/.nvm/versions/node/v22/bin/claude\n__INKLING_END__\nbye"
        #expect(ShellLookup.parse(noisy) == "/Users/u/.nvm/versions/node/v22/bin/claude")
        #expect(ShellLookup.parse("__INKLING_BEGIN__\nclaude not found\n__INKLING_END__") == nil)
        #expect(ShellLookup.parse("без маркеров /usr/bin/claude") == nil)
    }
}

@Suite("EngineRouter")
struct EngineRouterTests {
    /// Движок, который отвечает по сценарию и считает одновременные вызовы.
    actor FakeEngine: AIEngine {
        nonisolated let id: EngineID
        private var script: [Result<String, AIError>]
        private(set) var calls = 0
        private(set) var maxConcurrent = 0
        private var current = 0
        private let delay: Duration

        init(_ script: [Result<String, AIError>], delay: Duration = .zero) {
            id = .claude
            self.script = script
            self.delay = delay
        }

        func run(_ request: AIRequest) async throws(AIError) -> AIResponse {
            calls += 1
            current += 1
            maxConcurrent = max(maxConcurrent, current)
            defer { current -= 1 }
            if delay > .zero { try? await Task.sleep(for: delay) }
            let next = script.isEmpty ? .success("ok") : script.removeFirst()
            switch next {
            case .success(let text): return AIResponse(text: text, json: nil, engine: id, model: "fake", duration: 0)
            case .failure(let error): throw error
            }
        }

        nonisolated func checkConnection() async -> ConnectionReport { ConnectionReport() }
    }

    private let request = AIRequest(prompt: "p", systemPrompt: "s")
    private let limit = AIError.rateLimited(resetAt: nil, details: "limit")

    @Test func retriesOnceOnTimeout() async throws {
        let primary = FakeEngine([.failure(.timeout), .success("второй раз")])
        let router = EngineRouter(primary: primary, fallback: nil, settings: .init())
        #expect(try await router.run(request).text == "второй раз")
        #expect(await primary.calls == 2)
    }

    @Test func twoTimeoutsWithoutFallbackFail() async {
        let primary = FakeEngine([.failure(.timeout), .failure(.timeout)])
        let router = EngineRouter(primary: primary, fallback: nil, settings: .init())
        await #expect(throws: AIError.timeout) { try await router.run(request) }
        #expect(await primary.calls == 2)
    }

    @Test func twoInvalidOutputsGoToFallback() async throws {
        let primary = FakeEngine([.failure(.invalidOutput("a")), .failure(.invalidOutput("b"))])
        let fallback = FakeEngine([.success("запасной")])
        let events = EventLog()
        let router = EngineRouter(primary: primary, fallback: fallback, settings: .init())
        #expect(try await router.run(request, onEvent: events.add).text == "запасной")
        #expect(events.values.contains { if case .switchedToFallback = $0 { true } else { false } })
    }

    @Test func noRetryForAuthAndMissingBinary() async {
        for error in [AIError.notAuthenticated("x"), .binaryNotFound("y")] {
            let primary = FakeEngine([.failure(error)])
            let fallback = FakeEngine([.success("не должен")])
            let router = EngineRouter(primary: primary, fallback: fallback, settings: .init())
            await #expect(throws: error) { try await router.run(request) }
            #expect(await primary.calls == 1)
            #expect(await fallback.calls == 0)
        }
    }

    @Test func rateLimitSwitchesImmediatelyAndMarksPrimary() async throws {
        let clock = Clock(now: Date(timeIntervalSince1970: 1_000))
        let reset = Date(timeIntervalSince1970: 1_600)
        let primary = FakeEngine([.failure(.rateLimited(resetAt: reset, details: "x")), .success("основной снова")])
        let fallback = FakeEngine([.success("запасной 1"), .success("запасной 2")])
        let router = EngineRouter(primary: primary, fallback: fallback, settings: .init(), now: { clock.now })

        #expect(try await router.run(request).text == "запасной 1")
        #expect(await primary.calls == 1)
        #expect(await router.isLimited(.claude))

        // До сброса новые задания сразу идут на запасной.
        #expect(try await router.run(request).text == "запасной 2")
        #expect(await primary.calls == 1)

        clock.now = Date(timeIntervalSince1970: 1_601)
        #expect(try await router.run(request).text == "основной снова")
    }

    @Test func rateLimitWithoutAutoFallbackFails() async {
        let primary = FakeEngine([.failure(limit)])
        let fallback = FakeEngine([.success("x")])
        let router = EngineRouter(primary: primary, fallback: fallback, settings: .init(autoFallback: false))
        await #expect(throws: limit) { try await router.run(request) }
        #expect(await fallback.calls == 0)
    }

    @Test func unknownResetUsesCooldown() async throws {
        let clock = Clock(now: Date(timeIntervalSince1970: 0))
        let router = EngineRouter(primary: FakeEngine([.failure(limit)]), fallback: nil,
                                  settings: .init(unknownLimitCooldown: 60), now: { clock.now })
        _ = try? await router.run(request)
        #expect(await router.limitedUntil[.claude] == Date(timeIntervalSince1970: 60))
    }

    @Test func respectsParallelLimit() async throws {
        let primary = FakeEngine([], delay: .milliseconds(150))
        let router = EngineRouter(primary: primary, fallback: nil, settings: .init(maxParallel: 2))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 { group.addTask { _ = try await router.run(request) } }
            try await group.waitForAll()
        }
        #expect(await primary.calls == 5)
        #expect(await primary.maxConcurrent == 2)
    }

    @Test func cancelledBeforeStart() async {
        let router = EngineRouter(primary: FakeEngine([]), fallback: nil, settings: .init())
        let task = Task { () async throws -> AIResponse in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await router.run(request)
        }
        #expect(await Self.error(of: task) == .cancelled)
    }

    static func error(of task: Task<AIResponse, any Error>) async -> AIError? {
        if case .failure(let error) = await task.result { return error as? AIError }
        return nil
    }

    final class Clock: @unchecked Sendable {
        var now: Date
        init(now: Date) { self.now = now }
    }

    final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [EngineRouter.Event] = []
        var values: [EngineRouter.Event] { lock.withLock { storage } }
        @Sendable func add(_ event: EngineRouter.Event) { lock.withLock { storage.append(event) } }
    }
}

/// Настоящий вызов Claude Code. Запускается только с `TEST_RUNNER_INKLING_LIVE_CLAUDE=1`:
/// тратит лимит подписки и требует входа.
@Suite("Claude: живой вызов", .enabled(if: ProcessInfo.processInfo.environment["INKLING_LIVE_CLAUDE"] == "1"))
struct ClaudeLiveTests {
    private let engine = ClaudeCodeEngine(config: .init())

    @Test func recognizesImage() async throws {
        let png = RawCLI.folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestData/synthetic/chem-page.png")
        let response = try await engine.run(AIRequest(
            prompt: "Перепиши текст с изображения в Markdown, химию через \\ce{}. Изображение: ./chem-page.png",
            systemPrompt: "Ты переписываешь фотографии конспектов. Изображение читай инструментом Read. Выводи только Markdown.",
            images: [png], timeout: 120))
        #expect(response.text.contains("ce{"))
        #expect(response.model.hasPrefix("claude-"))
    }

    @Test func structuredJSON() async throws {
        let schema = #"{"type":"object","properties":{"answer":{"type":"integer"}},"required":["answer"]}"#
        let response = try await engine.run(AIRequest(prompt: "Сколько будет 2+3?", systemPrompt: "Отвечай кратко.",
                                                      format: .json(schema: schema), timeout: 90))
        let data = try #require(response.json)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["answer"] as? Int == 5)
    }

    @Test func badModel() async {
        let engine = ClaudeCodeEngine(config: .init(model: "no-such-model-xyz"))
        do {
            _ = try await engine.run(AIRequest(prompt: "hi", systemPrompt: "s", timeout: 60))
            Issue.record("Ожидалась ошибка")
        } catch {
            #expect(error.isModelUnavailable)
        }
    }

    @Test func cancelRealCall() async throws {
        let task = Task { () async throws -> AIResponse in
            try await engine.run(AIRequest(prompt: "Напиши длинное эссе на 3000 слов о химии.", systemPrompt: "s",
                                           timeout: 300))
        }
        try await Task.sleep(for: .seconds(3))
        task.cancel()
        #expect(await EngineRouterTests.error(of: task) == .cancelled)
    }

    @Test func connectionCheck() async {
        let report = await engine.checkConnection()
        #expect(report.isOK, "\(report)")
        #expect(report.version?.contains("Claude Code") == true)
    }
}
