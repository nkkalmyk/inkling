import Foundation
import Testing
@testable import Inkling

/// Хранилище секретов в памяти.
final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func read(account: String) -> String? { lock.withLock { values[account] } }
    @discardableResult func write(_ value: String, account: String) -> Bool { lock.withLock { values[account] = value }; return true }
    func delete(account: String) { _ = lock.withLock { values.removeValue(forKey: account) } }
}

/// HTTP-ответы для `GeminiEngine` без сети.
final class FakeGemini: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [URLRequest] = []
    /// Ответы по очереди; когда кончатся — последний повторяется.
    var replies: [(Data, Int)] = []
    var delay: Duration = .zero

    var requests: [URLRequest] { lock.withLock { sent } }

    var transport: GeminiEngine.Transport {
        { [self] request in
            let (data, status) = lock.withLock { () -> (Data, Int) in
                sent.append(request)
                return replies.count > 1 ? replies.removeFirst() : (replies.first ?? (Data(), 200))
            }
            if delay > .zero { try await Task.sleep(for: delay) }
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    static func answer(_ text: String, finish: String = "STOP", model: String = "gemini-3.5-flash") -> (Data, Int) {
        let json: [String: Any] = ["candidates": [["content": ["role": "model", "parts": [["text": text]]], "finishReason": finish]],
                                   "modelVersion": model]
        return (try! JSONSerialization.data(withJSONObject: json), 200)
    }

    static func error(_ status: Int, _ code: String, _ message: String, details: [[String: Any]] = []) -> (Data, Int) {
        let json: [String: Any] = ["error": ["code": status, "message": message, "status": code, "details": details]]
        return (try! JSONSerialization.data(withJSONObject: json), status)
    }
}

@Suite("Gemini: запрос и ответ")
struct GeminiParsingTests {
    private func body(_ request: AIRequest, images: [Data] = []) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: GeminiEngine.requestBody(request, images: images)) as? [String: Any])
    }

    private func texts(_ json: [String: Any]) throws -> (system: String, user: String) {
        let system = ((json["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"] as? String
        let contents = try #require(json["contents"] as? [[String: Any]])
        let user = (contents[0]["parts"] as? [[String: Any]])?.first?["text"] as? String
        return (try #require(system), try #require(user))
    }

    @Test func textRequestKeepsAppPrompts() throws {
        let json = try body(AIRequest(prompt: "собери", systemPrompt: "Ты собираешь конспект"))
        let (system, user) = try texts(json)
        #expect(system == "Ты собираешь конспект")
        #expect(user == "собери")
        #expect((json["generationConfig"] as? [String: Any])?["temperature"] as? Int == 0)
        #expect((json["generationConfig"] as? [String: Any])?["responseMimeType"] == nil)
    }

    @Test func singlePageRecognitionUsesTranscriberPromptAndInlineImage() throws {
        let request = AIRequest(prompt: "Это фотография конспекта по предмету «Общая химия». Перепиши страницу.\n\nИзображение: ./abc.jpg",
                                systemPrompt: PromptLibrary.recognitionSystemPrompt)
        let json = try body(request, images: [Data([1, 2, 3])])
        let (system, user) = try texts(json)
        #expect(system == OllamaEngine.recognitionSystemPrompt)
        #expect(user == "Это фотография конспекта. Перепиши страницу.")
        let parts = try #require((json["contents"] as? [[String: Any]])?[0]["parts"] as? [[String: Any]])
        let inline = try #require(parts[1]["inline_data"] as? [String: String])
        #expect(inline["mime_type"] == "image/jpeg")
        #expect(inline["data"] == Data([1, 2, 3]).base64EncodedString())
    }

    @Test func multiImageRequestKeepsPromptButDropsReadToolHint() throws {
        let request = AIRequest(prompt: "фрагменты: ./a.jpg ./b.jpg", systemPrompt: PromptLibrary.recognitionSystemPrompt)
        let (system, user) = try texts(try body(request, images: [Data([1]), Data([2])]))
        #expect(user == "фрагменты: ./a.jpg ./b.jpg")
        #expect(!system.contains("инструментом Read"))
        #expect(system.contains("приложенных к запросу изображениях"))
    }

    @Test func jsonFormatAsksForJSONAndPutsSchemaInPrompt() throws {
        let schema = #"{"type":"object","properties":{"a":{"type":"integer"}},"additionalProperties":false}"#
        let json = try body(AIRequest(prompt: "p", systemPrompt: "s", format: .json(schema: schema)))
        #expect((json["generationConfig"] as? [String: Any])?["responseMimeType"] as? String == "application/json")
        #expect(json["responseSchema"] == nil)
        #expect(try texts(json).system.contains(schema))
    }

    @Test func parsesTextAndSkipsThoughts() throws {
        let json: [String: Any] = ["candidates": [["content": ["parts": [["text": "размышление", "thought": true],
                                                                         ["text": "  # Тема\n"]]], "finishReason": "STOP"]],
                                   "modelVersion": "gemini-3.5-flash"]
        let data = try JSONSerialization.data(withJSONObject: json)
        let response = try GeminiEngine.parse(data: data, status: 200, format: .text, requestedModel: "m", duration: 2).get()
        #expect(response.text == "# Тема")
        #expect(response.engine == .gemini)
        #expect(response.model == "gemini-3.5-flash")
    }

    @Test func extractsJSONFromFencedAnswer() throws {
        let (data, status) = FakeGemini.answer("Вот:\n```json\n{\"a\": 1}\n```")
        let response = try GeminiEngine.parse(data: data, status: status, format: .json(schema: nil), requestedModel: "m",
                                              duration: 0).get()
        let payload = try #require(response.json)
        let object = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Int])
        #expect(object == ["a": 1])
    }

    @Test func truncatedEmptyAndBlockedAnswersAreInvalid() {
        let cut = FakeGemini.answer("обрыв", finish: "MAX_TOKENS")
        #expect(throws: AIError.self) { try GeminiEngine.parse(data: cut.0, status: 200, format: .text, requestedModel: "m", duration: 0).get() }
        let empty = FakeGemini.answer("  ")
        guard case .failure(.invalidOutput) = GeminiEngine.parse(data: empty.0, status: 200, format: .text, requestedModel: "m", duration: 0) else {
            Issue.record("пустой ответ должен быть invalidOutput")
            return
        }
        let blocked = Data(#"{"promptFeedback":{"blockReason":"SAFETY"}}"#.utf8)
        guard case .failure(.invalidOutput(let text)) = GeminiEngine.parse(data: blocked, status: 200, format: .text, requestedModel: "m", duration: 0) else {
            Issue.record("блокировка должна быть invalidOutput")
            return
        }
        #expect(text.contains("SAFETY"))
    }

    // MARK: Ошибки API

    private func failure(_ reply: (Data, Int), model: String = "m", now: Date = Date(timeIntervalSince1970: 1_000)) -> AIError? {
        if case .failure(let error) = GeminiEngine.parse(data: reply.0, status: reply.1, format: .text, requestedModel: model,
                                                         duration: 0, now: now) { return error }
        return nil
    }

    @Test func quotaErrorUsesRetryDelay() {
        let reply = FakeGemini.error(429, "RESOURCE_EXHAUSTED", "Quota exceeded",
                                     details: [["@type": "type.googleapis.com/google.rpc.RetryInfo", "retryDelay": "34.5s"]])
        guard case .rateLimited(let resetAt, let details) = failure(reply) else { Issue.record("ожидался rateLimited"); return }
        #expect(resetAt == Date(timeIntervalSince1970: 1_034.5))
        #expect(details == "Quota exceeded")
    }

    @Test func quotaErrorWithoutDelayWaitsAMinute() {
        guard case .rateLimited(let resetAt, _) = failure(FakeGemini.error(429, "RESOURCE_EXHAUSTED", "x")) else {
            Issue.record("ожидался rateLimited"); return
        }
        #expect(resetAt == Date(timeIntervalSince1970: 1_060))
    }

    @Test func badKeyAndForbiddenAreAuthErrors() {
        let invalid = FakeGemini.error(400, "INVALID_ARGUMENT", "API key not valid. Please pass a valid API key.")
        #expect(failure(invalid) == .geminiNotAuthenticated("API key not valid. Please pass a valid API key."))
        guard case .geminiNotAuthenticated = failure(FakeGemini.error(403, "PERMISSION_DENIED", "denied")) else {
            Issue.record("403 должен быть ошибкой доступа"); return
        }
    }

    @Test func missingModelAndOverloadAreMapped() {
        #expect(failure(FakeGemini.error(404, "NOT_FOUND", "models/x is not found"), model: "x") == .geminiModelUnavailable(model: "x"))
        let overload = failure(FakeGemini.error(503, "UNAVAILABLE", "high demand"))
        #expect(overload == .processFailed(exitCode: 503, stderr: "high demand"))
        #expect(overload?.isRetryable == true)
    }

    @Test func nonJSONErrorKeepsBody() {
        #expect(failure((Data("Bad gateway".utf8), 502)) == .processFailed(exitCode: 502, stderr: "Bad gateway"))
    }
}

@Suite("Gemini: запуск")
struct GeminiRunTests {
    private func engine(_ fake: FakeGemini, key: String? = "test-key", model: String = "gemini-3.5-flash") -> GeminiEngine {
        GeminiEngine(config: .init(model: model), apiKey: { key }, transport: fake.transport,
                     now: { Date(timeIntervalSince1970: 1_000) })
    }

    private let request = AIRequest(prompt: "привет", systemPrompt: "кратко", timeout: 5)

    @Test func sendsKeyInHeaderNotInURL() async throws {
        let fake = FakeGemini()
        fake.replies = [FakeGemini.answer("ок")]
        let response = try await engine(fake).run(request)
        #expect(response.text == "ок")
        let sent = try #require(fake.requests.first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "x-goog-api-key") == "test-key")
        let url = try #require(sent.url?.absoluteString)
        #expect(url == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent")
        #expect(!url.contains("test-key"))
        #expect(!String(decoding: sent.httpBody ?? Data(), as: UTF8.self).contains("test-key"))
    }

    @Test func missingKeyFailsBeforeAnyRequest() async {
        let fake = FakeGemini()
        for key in [nil, ""] as [String?] {
            await #expect(throws: AIError.self) { try await engine(fake, key: key).run(request) }
        }
        #expect(fake.requests.isEmpty)
    }

    @Test func requestModelOverridesSettings() async throws {
        let fake = FakeGemini()
        fake.replies = [FakeGemini.answer("ок")]
        var custom = request
        custom.model = "gemini-3-flash-preview"
        _ = try await engine(fake).run(custom)
        #expect(fake.requests.first?.url?.path.contains("gemini-3-flash-preview") == true)
    }

    @Test func overloadedModelFallsBackToSpare() async throws {
        let fake = FakeGemini()
        fake.replies = [FakeGemini.error(503, "UNAVAILABLE", "high demand"), FakeGemini.answer("ок", model: "gemini-3.5-flash-lite")]
        let response = try await engine(fake).run(request)
        #expect(response.model == "gemini-3.5-flash-lite")
        #expect(fake.requests.map { $0.url?.lastPathComponent } == ["gemini-3.5-flash:generateContent",
                                                                  "gemini-flash-lite-latest:generateContent"])
    }

    @Test func quotaOnMainModelFallsBackButQuotaOnBothIsALimit() async throws {
        let quota = FakeGemini.error(429, "RESOURCE_EXHAUSTED", "quota")
        let fake = FakeGemini()
        fake.replies = [quota, FakeGemini.answer("ок")]
        #expect(try await engine(fake).run(request).text == "ок")

        let both = FakeGemini()
        both.replies = [quota]
        await #expect(throws: AIError.self) { try await engine(both).run(request) }
        #expect(both.requests.count == 2)
    }

    @Test func spareModelHasNoSpare() async {
        let fake = FakeGemini()
        fake.replies = [FakeGemini.error(503, "UNAVAILABLE", "x")]
        await #expect(throws: AIError.self) { try await engine(fake, model: GeminiEngine.Config.spareModel).run(request) }
        #expect(fake.requests.count == 1)
    }

    @Test func badKeyDoesNotTrySpare() async {
        let fake = FakeGemini()
        fake.replies = [FakeGemini.error(400, "INVALID_ARGUMENT", "API key not valid")]
        await #expect(throws: AIError.self) { try await engine(fake).run(request) }
        #expect(fake.requests.count == 1)
    }

    @Test func hangingRequestTimesOut() async {
        let fake = FakeGemini()
        fake.replies = [FakeGemini.answer("поздно")]
        fake.delay = .seconds(5)
        var quick = request
        quick.timeout = 0.2
        await #expect(throws: AIError.timeout) { try await engine(fake, model: GeminiEngine.Config.spareModel).run(quick) }
    }

    @Test func connectionCheckReportsModelAndErrors() async {
        let fake = FakeGemini()
        fake.replies = [FakeGemini.answer("готово", model: "gemini-3.5-flash")]
        let ok = await engine(fake).checkConnection()
        #expect(ok.isOK)
        #expect(ok.model == "gemini-3.5-flash")
        let noKey = await engine(FakeGemini(), key: nil).checkConnection()
        #expect(!noKey.isOK)
        guard case .geminiNotAuthenticated = noKey.error else { Issue.record("ожидалась ошибка ключа"); return }
    }
}

@Suite("Gemini: связка ключей")
struct KeychainSecretStoreTests {
    @Test func roundTripUpdateAndDelete() {
        let store = KeychainSecretStore(service: "com.nkalmykov.inkling.tests.\(UUID().uuidString)")
        defer { store.delete(account: "key") }
        #expect(store.read(account: "key") == nil)
        #expect(store.write("первый", account: "key"))
        #expect(store.read(account: "key") == "первый")
        #expect(store.write("второй", account: "key"))
        #expect(store.read(account: "key") == "второй")
        store.delete(account: "key")
        #expect(store.read(account: "key") == nil)
    }
}

@Suite("Gemini: настройки и маршрут")
@MainActor
struct GeminiSettingsTests {
    private func settings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: "gemini-tests-\(UUID().uuidString)")!)
    }

    @Test func keyLivesInSecretStoreNotInDefaults() {
        let store = MemorySecretStore()
        let center = EngineCenter(settings: settings(), secrets: store)
        #expect(!center.geminiKeyStored)
        #expect(center.saveGeminiKey("  secret-key \n"))
        #expect(center.geminiKeyStored)
        #expect(store.read(account: EngineCenter.geminiKeyAccount) == "secret-key")
        #expect(center.saveGeminiKey(""))
        #expect(!center.geminiKeyStored)
        #expect(store.read(account: EngineCenter.geminiKeyAccount) == nil)
    }

    @Test func geminiEngineReadsKeyAtCallTime() {
        let store = MemorySecretStore()
        let center = EngineCenter(settings: settings(), secrets: store)
        let engine = center.engine(.gemini)
        #expect(engine.id == .gemini)
        let gemini = engine as? GeminiEngine
        #expect(gemini?.apiKey() == nil)
        store.write("late-key", account: EngineCenter.geminiKeyAccount)
        #expect(gemini?.apiKey() == "late-key")
        #expect(gemini?.config.model == GeminiEngine.Config.defaultModel)
    }

    @Test func routingKnowsGemini() {
        let only = EngineCenter.routing(mode: .geminiOnly, primary: .claude, fallback: .none)
        #expect(only.primary == .gemini)
        #expect(only.fallback == nil)
        let auto = EngineCenter.routing(mode: .auto, primary: .claude, fallback: .gemini)
        #expect(auto.primary == .claude)
        #expect(auto.fallback == .gemini)
        #expect(EngineID.gemini.isCloud)
        #expect(!EngineID.gemini.needsReview)
    }

    @Test func routerFallsBackToGeminiOnLimit() async throws {
        let fake = FakeGemini()
        fake.replies = [FakeGemini.answer("из Gemini")]
        let gemini = GeminiEngine(apiKey: { "k" }, transport: fake.transport)
        let router = EngineRouter(primary: LimitedEngine(), fallback: gemini, settings: .init())
        let response = try await router.run(AIRequest(prompt: "p", systemPrompt: "s", timeout: 5))
        #expect(response.engine == .gemini)
        #expect(response.text == "из Gemini")
    }
}

/// Движок, у которого всегда исчерпан лимит.
private struct LimitedEngine: AIEngine {
    let id = EngineID.claude
    func run(_ request: AIRequest) async throws(AIError) -> AIResponse { throw .rateLimited(resetAt: nil, details: "limit") }
    func checkConnection() async -> ConnectionReport { ConnectionReport() }
}
