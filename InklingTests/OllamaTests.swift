import CoreImage
import Foundation
import Testing
@testable import Inkling

/// HTTP-ответы для `OllamaEngine` без настоящего сервера.
final class FakeOllama: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [Data] = []
    private var paths: [String] = []
    var chat: (Data, Int) = (Data(), 200)
    /// Ответы `/api/chat` по очереди; когда кончатся — `chat`.
    var chatSequence: [(Data, Int)] = []
    var delay: Duration = .zero
    var up = true

    var requests: [[String: Any]] {
        lock.withLock { bodies.compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } }
    }
    var requestedPaths: [String] { lock.withLock { paths } }

    var transport: OllamaEngine.Transport {
        { [self] request in
            let path = request.url?.path ?? ""
            lock.withLock {
                paths.append(path)
                if let body = request.httpBody { bodies.append(body) }
            }
            guard up else { throw URLError(.cannotConnectToHost) }
            // Задержка только у генерации: проверка версии должна отвечать сразу, иначе движок пойдёт запускать сервер.
            if delay > .zero, path == "/api/chat" { try await Task.sleep(for: delay) }
            let (data, status): (Data, Int)
            switch path {
            case "/api/version": (data, status) = (Data(#"{"version":"0.40.4"}"#.utf8), 200)
            case "/api/tags": (data, status) = (Data(#"{"models":[{"name":"qwen3.5:9b"},{"name":"inkling-ocr:latest"}]}"#.utf8), 200)
            default: (data, status) = lock.withLock { chatSequence.isEmpty ? chat : chatSequence.removeFirst() }
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (data, response)
        }
    }

    static func chatReply(_ content: String, doneReason: String = "stop", model: String = "inkling-ocr:latest") -> Data {
        let json: [String: Any] = ["model": model, "message": ["role": "assistant", "content": content],
                                   "done": true, "done_reason": doneReason]
        return try! JSONSerialization.data(withJSONObject: json)
    }
}

@Suite("Ollama: запрос и ответ")
struct OllamaParsingTests {
    private func body(_ request: AIRequest, images: [Data] = []) throws -> [String: Any] {
        let data = OllamaEngine.chatBody(request, model: "inkling-ocr", images: images)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func textRequestKeepsAppSystemPrompt() throws {
        let json = try body(AIRequest(prompt: "собери", systemPrompt: "Ты собираешь конспект"))
        #expect(json["model"] as? String == "inkling-ocr")
        #expect(json["stream"] as? Bool == false)
        #expect(json["think"] as? Bool == false)
        #expect(json["format"] == nil)
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages[0]["content"] as? String == "Ты собираешь конспект")
        #expect(messages[1]["content"] as? String == "собери")
        #expect(messages[1]["images"] == nil)
        let options = try #require(json["options"] as? [String: Any])
        #expect(options["temperature"] as? Int == 0)
        #expect(options["presence_penalty"] as? Int == 0)
        #expect((options["num_ctx"] as? Int ?? 0) >= 12_288)
    }

    @Test func imageRequestUsesLocalPromptAndDropsFileReference() throws {
        let request = AIRequest(prompt: "Это фотография конспекта по предмету «Общая химия». Перепиши страницу.\n\nИзображение: ./abc-123.jpg",
                                systemPrompt: PromptLibrary.recognitionSystemPrompt)
        let json = try body(request, images: [Data([1, 2, 3])])
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages[0]["content"] as? String == OllamaEngine.recognitionSystemPrompt)
        #expect(messages[1]["content"] as? String == "Это фотография конспекта. Перепиши страницу.")
        #expect(messages[1]["images"] as? [String] == [Data([1, 2, 3]).base64EncodedString()])
        #expect((json["options"] as? [String: Any])?["num_predict"] as? Int == OllamaEngine.recognitionTokenLimit)
    }

    @Test func jsonFormatPassesSchemaObject() throws {
        let schema = #"{"type":"object","properties":{"a":{"type":"integer"}}}"#
        let json = try body(AIRequest(prompt: "p", systemPrompt: "s", format: .json(schema: schema)))
        let format = try #require(json["format"] as? [String: Any])
        #expect(format["type"] as? String == "object")
        let plain = try body(AIRequest(prompt: "p", systemPrompt: "s", format: .json(schema: nil)))
        #expect(plain["format"] as? String == "json")
    }

    @Test func parsesText() throws {
        let result = OllamaEngine.parse(data: FakeOllama.chatReply("  # Тема\n"), status: 200, format: .text,
                                        requestedModel: "inkling-ocr", duration: 2)
        let response = try result.get()
        #expect(response.text == "# Тема")
        #expect(response.engine == .ollama)
        #expect(response.model == "inkling-ocr:latest")
    }

    @Test func extractsJSONFromText() throws {
        let reply = FakeOllama.chatReply("Вот:\n```json\n{\"a\": 1}\n```")
        let response = try OllamaEngine.parse(data: reply, status: 200, format: .json(schema: nil),
                                              requestedModel: "m", duration: 0).get()
        let data = try #require(response.json)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Int])
        #expect(object == ["a": 1])
    }

    @Test func classifiesErrors() {
        func parse(_ data: Data, _ status: Int, format: AIRequest.Format = .text) -> AIError? {
            if case .failure(let error) = OllamaEngine.parse(data: data, status: status, format: format,
                                                             requestedModel: "inkling-ocr", duration: 0) { return error }
            return nil
        }
        #expect(parse(Data(#"{"error":"model 'inkling-ocr' not found"}"#.utf8), 404) == .modelNotInstalled(model: "inkling-ocr"))
        #expect(parse(Data(#"{"error":"out of memory"}"#.utf8), 500) == .processFailed(exitCode: 500, stderr: "out of memory"))
        if case .invalidOutput = parse(FakeOllama.chatReply("   "), 200) {} else { Issue.record("Пустой ответ — invalidOutput") }
        if case .invalidOutput(let s) = parse(FakeOllama.chatReply("начало"), 200) { Issue.record("Лишняя ошибка: \(s)") }
        if case .invalidOutput = parse(FakeOllama.chatReply("обрыв", doneReason: "length"), 200) {} else {
            Issue.record("Обрезанный ответ — invalidOutput")
        }
        if case .invalidOutput = parse(FakeOllama.chatReply("без json"), 200, format: .json(schema: nil)) {} else {
            Issue.record("Нет JSON — invalidOutput")
        }
        if case .invalidOutput = parse(Data("мусор".utf8), 200) {} else { Issue.record("Мусор — invalidOutput") }
    }

    @Test func newErrorsAreTerminal() {
        for error in [AIError.ollamaUnavailable("x"), .modelNotInstalled(model: "m")] {
            #expect(!error.isRetryable)
            #expect(!EngineRouter.shouldFallBack(after: error))
            #expect(error.userMessage.contains("Ollama"))
        }
    }

    @Test func parsesInstalledModels() {
        let data = Data(#"{"models":[{"name":"qwen3.5:9b"},{"name":"inkling-ocr:latest"}]}"#.utf8)
        #expect(OllamaEngine.parseModels(data) == ["inkling-ocr:latest", "qwen3.5:9b"])
        #expect(OllamaEngine.parseModels(Data("{}".utf8)).isEmpty)
    }

    @Test func upscalesOnlySmallImages() {
        func longest(_ w: CGFloat, _ h: CGFloat) -> CGFloat {
            let image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
            let out = ImageProcessor.upscaledForModel(image).extent
            return max(out.width, out.height)
        }
        #expect(longest(800, 600) == 1600)
        #expect(longest(850, 1060) == 2000)
        #expect(longest(1700, 1500) == 1700)
    }

    @Test func markdownWrapperIsRemoved() {
        #expect(MarkdownCleanup.unwrap("```markdown\n# Тема\n$x$\n```") == "# Тема\n$x$")
        #expect(MarkdownCleanup.unwrap("# Тема\n```python\nx\n```") == "# Тема\n```python\nx\n```")
    }
}

@Suite("Ollama: запуск")
struct OllamaRuntimeTests {
    private let base = URL(string: "http://127.0.0.1:11434")!

    private func engine(_ fake: FakeOllama, server: OllamaServer = OllamaServer()) -> OllamaEngine {
        OllamaEngine(config: .init(model: "inkling-ocr"), server: server, transport: fake.transport)
    }

    @Test func runsRequestThroughChat() async throws {
        let fake = FakeOllama()
        fake.chat = (FakeOllama.chatReply("ответ"), 200)
        let response = try await engine(fake).run(AIRequest(prompt: "привет", systemPrompt: "s", timeout: 5))
        #expect(response.text == "ответ")
        #expect(fake.requestedPaths == ["/api/version", "/api/chat"])
        #expect(fake.requests.first?["model"] as? String == "inkling-ocr")
    }

    @Test func sendsPreparedImage() async throws {
        let dir = try TempDir()
        let url = Fixtures.write(Fixtures.halfRed(), to: dir.url.appendingPathComponent("p.jpg"))
        let fake = FakeOllama()
        fake.chat = (FakeOllama.chatReply("# страница"), 200)
        _ = try await engine(fake).run(AIRequest(prompt: "p\n\nИзображение: ./p.jpg", systemPrompt: "s",
                                                 images: [url], timeout: 5))
        let messages = try #require(fake.requests.first?["messages"] as? [[String: Any]])
        let image = try #require((messages[1]["images"] as? [String])?.first.flatMap { Data(base64Encoded: $0) })
        #expect(image.starts(with: [0xFF, 0xD8]), "JPEG")
    }

    @Test func structuredOutputFallsBackToSchemaInPrompt() async throws {
        let fake = FakeOllama()
        let schema = #"{"type":"object","properties":{"answer":{"type":"integer"}}}"#
        fake.chatSequence = [(Data(#"{"error":"structured output is unavailable"}"#.utf8), 501),
                             (FakeOllama.chatReply(#"{"answer": 4}"#), 200)]
        let response = try await engine(fake).run(AIRequest(prompt: "2+2", systemPrompt: "Кратко.",
                                                             format: .json(schema: schema), timeout: 5))
        #expect(response.json != nil)
        let chats = fake.requests
        #expect(chats.count == 2)
        #expect(chats[0]["format"] != nil)
        #expect(chats[1]["format"] == nil)
        let system = (chats[1]["messages"] as? [[String: Any]])?.first?["content"] as? String ?? ""
        #expect(system.hasPrefix("Кратко.") && system.contains(schema))
    }

    @Test func timeoutIsEnforced() async {
        let fake = FakeOllama()
        fake.delay = .seconds(10)
        let request = URLRequest(url: base.appendingPathComponent("api/chat"))
        let started = Date()
        await #expect(throws: AIError.timeout) { try await OllamaEngine.send(request, timeout: 0.2, transport: fake.transport) }
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func cancellationStopsRequest() async {
        let fake = FakeOllama()
        fake.delay = .seconds(10)
        let engine = engine(fake)
        let task = Task { try await engine.run(AIRequest(prompt: "p", systemPrompt: "s", timeout: 30)) }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let result = await task.result
        guard case .failure(let error) = result else { Issue.record("Ожидалась отмена"); return }
        #expect(error as? AIError == .cancelled)
    }

    @Test func missingBinaryWhenServerIsDown() async {
        let fake = FakeOllama()
        fake.up = false
        let locator = BinaryLocator(home: "/nonexistent", isExecutable: { _ in false }, contentsOfDirectory: { _ in [] },
                                    fileHeader: { _ in "" }, shellLookup: { _ in nil })
        let server = OllamaServer(locator: locator, startupTimeout: 1)
        do {
            _ = try await engine(fake, server: server).run(AIRequest(prompt: "p", systemPrompt: "s", timeout: 5))
            Issue.record("Ожидалась ошибка")
        } catch {
            guard case .ollamaUnavailable(let details) = error else { Issue.record("Получено \(error)"); return }
            #expect(details.contains("ollama"))
        }
    }

    @Test func serverThatNeverAnswersIsStopped() async throws {
        let dir = try TempDir()
        let fakeBinary = dir.url.appendingPathComponent("ollama")
        try "#!/bin/sh\nsleep 30\n".write(to: fakeBinary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBinary.path)
        let fake = FakeOllama()
        fake.up = false
        let server = OllamaServer(startupTimeout: 1)
        do {
            try await server.ensureRunning(manualPath: fakeBinary.path, baseURL: base, transport: fake.transport)
            Issue.record("Ожидалась ошибка")
        } catch {
            guard case .ollamaUnavailable(let details) = error else { Issue.record("Получено \(error)"); return }
            #expect(details.contains("не ответил"))
        }
    }

    @Test func oneRequestAtATime() async throws {
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var current = 0, peak = 0
            func enter() { lock.withLock { current += 1; peak = max(peak, current) } }
            func leave() { lock.withLock { current -= 1 } }
        }
        let server = OllamaServer()
        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    _ = try? await server.exclusively { () async throws(AIError) -> Int in
                        counter.enter()
                        try? await Task.sleep(for: .milliseconds(50))
                        counter.leave()
                        return 0
                    }
                }
            }
        }
        #expect(counter.peak == 1)
    }

    @Test func installedModelsAndConnectionCheck() async throws {
        let fake = FakeOllama()
        fake.chat = (FakeOllama.chatReply("готово"), 200)
        let engine = engine(fake)
        #expect(try await engine.installedModels() == ["inkling-ocr:latest", "qwen3.5:9b"])
        let report = await engine.checkConnection()
        #expect(report.isOK)
        #expect(report.version == "0.40.4")

        var other = engine
        other.config.model = "нет-такой"
        #expect(await other.checkConnection().error == .modelNotInstalled(model: "нет-такой"))
    }
}

@Suite("Выбор движка")
@MainActor
struct EngineChoiceTests {
    @Test func routingFollowsModeAndSettings() {
        typealias E = AppSettings.Engine
        #expect(EngineCenter.routing(mode: .auto, primary: .claude, fallback: .ollama) == (.claude, .ollama))
        #expect(EngineCenter.routing(mode: .auto, primary: .claude, fallback: .none) == (.claude, nil))
        #expect(EngineCenter.routing(mode: .auto, primary: .ollama, fallback: .ollama) == (.ollama, nil))
        #expect(EngineCenter.routing(mode: .claudeOnly, primary: .ollama, fallback: .ollama) == (.claude, nil))
        #expect(EngineCenter.routing(mode: .localOnly, primary: .claude, fallback: .claude) == (.ollama, nil))
    }

    @Test func settingsPersistModeAndModels() throws {
        let suite = "InklingTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { discardDefaultsSuite(suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.engineMode == .auto)
        #expect(settings.ollamaModel == "inkling-ocr")
        settings.engineMode = .localOnly
        settings.ollamaModel = "qwen3.5:9b"
        settings.fallbackEngine = .ollama
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.engineMode == .localOnly)
        #expect(reloaded.ollamaModel == "qwen3.5:9b")
        #expect(reloaded.fallbackEngine == .ollama)
    }

    @Test func localEngineLowersChunkThreshold() throws {
        let suite = "InklingTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { discardDefaultsSuite(suite) }
        let settings = AppSettings(defaults: defaults)
        let engines = EngineCenter(settings: settings)
        #expect(engines.chunkThreshold == 40_000)
        settings.engineMode = .localOnly
        #expect(engines.chunkThreshold == EngineCenter.localChunkThreshold)
        settings.chunkThresholdChars = 10_000
        #expect(engines.chunkThreshold == 10_000)
        #expect(engines.router.primaryID == .ollama)
    }

    @Test func limitedClaudeFallsBackToLocal() async throws {
        let claude = EngineRouterTests.FakeEngine([.failure(.rateLimited(resetAt: nil, details: "limit"))])
        let local = EngineRouterTests.FakeEngine([.success("локально")], id: .ollama)
        let router = EngineRouter(primary: claude, fallback: local, settings: .init())
        let response = try await router.run(AIRequest(prompt: "p", systemPrompt: "s"))
        #expect(response.text == "локально")
        #expect(response.engine == .ollama)
    }
}

/// Настоящая Ollama с моделью `inkling-ocr`. Запускается только с `TEST_RUNNER_INKLING_LIVE_OLLAMA=1`:
/// нужна установленная модель (docs/INSTALL.md), занимает ~9 ГБ памяти и греет Mac.
@Suite("Ollama: живой вызов", .enabled(if: ProcessInfo.processInfo.environment["INKLING_LIVE_OLLAMA"] == "1"),
       .serialized)
struct OllamaLiveTests {
    private let engine = OllamaEngine(config: .init())

    private static var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test func recognizesImage() async throws {
        let png = Self.repo.appendingPathComponent("TestData/synthetic/chem-page.png")
        let response = try await engine.run(AIRequest(
            prompt: "Перепиши текст с изображения в Markdown, химию через \\ce{}.\n\nИзображение: ./chem-page.png",
            systemPrompt: PromptLibrary.recognitionSystemPrompt, images: [png], timeout: 120))
        #expect(response.text.contains("ce{"))
        #expect(response.text.contains("Окислитель"))
        #expect(response.engine == .ollama)
    }

    @Test func structuredJSON() async throws {
        let schema = #"{"type":"object","properties":{"answer":{"type":"integer"}},"required":["answer"]}"#
        let response = try await engine.run(AIRequest(prompt: "Сколько будет 2+2? Ответь JSON.", systemPrompt: "Отвечай кратко.",
                                                      format: .json(schema: schema), timeout: 60))
        let data = try #require(response.json)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Int])
        #expect(json["answer"] == 4)
    }
}
