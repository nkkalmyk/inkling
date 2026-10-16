import Foundation
import Testing
@testable import Inkling

@Suite("Дополнение конспекта")
struct EnrichmentTests {
    static let base = """
    # Пределы

    Предел функции в точке — число, к которому стремится значение.

    $$\\lim_{x\\to 0} \\frac{\\sin x}{x} = 1$$

    ## Свойства

    Предел суммы равен сумме пределов.

    > ⚠️ Возможно, ошибка: проверьте знак.
    """

    static let enriched = """
    ## 🧭 Главное

    - Предел — число, к которому стремится функция.
    - Предел суммы — сумма пределов.

    # Пределы

    **Предел** функции в точке — число, к которому стремится значение.

    > 💡 Пояснение: значения подходят к числу сколь угодно близко.

    $$\\lim_{x\\to 0} \\frac{\\sin x}{x} = 1$$

    ```plot
    {"x": [-6, 6], "functions": [{"expr": "sin(x)/x"}]}
    ```

    ## Свойства

    Предел суммы равен сумме пределов.

    > 📝 Пример: $\\lim (x + 1) = 1$ при $x \\to 0$.

    > ⚠️ Возможно, ошибка: проверьте знак.
    """

    @Test func findsAllAdditionKinds() {
        let kinds = Enrichment.additions(in: Self.enriched).map(\.kind)
        #expect(kinds == [.summary, .explanation, .plot, .example])
    }

    @Test func authorWarningIsNotAnAddition() {
        #expect(Enrichment.additions(in: Self.base).isEmpty)
        let merged = "> 💡 Пояснение: текст.\n> ⚠️ Возможно, ошибка: х."
        #expect(Enrichment.additions(in: merged).count == 1)
        #expect(Enrichment.additions(in: merged)[0].lines == 0..<1)
    }

    @Test func authorTextIsPreservedWhenOnlyAdditionsAndBold() {
        #expect(Enrichment.preservesAuthorText(original: Self.base, enriched: Self.enriched))
    }

    @Test func changedWordIsDetected() {
        let changed = Self.enriched.replacingOccurrences(of: "сумме пределов", with: "произведению пределов")
        #expect(!Enrichment.preservesAuthorText(original: Self.base, enriched: changed))
        let dropped = Self.enriched.replacingOccurrences(of: "Предел суммы равен сумме пределов.\n", with: "")
        #expect(!Enrichment.preservesAuthorText(original: Self.base, enriched: dropped))
    }

    @Test func removingAllRestoresBaseText() {
        let removed = Enrichment.removing(from: Self.enriched)
        #expect(Enrichment.additions(in: removed).isEmpty)
        #expect(Enrichment.comparableText(removed) == Enrichment.comparableText(Self.base))
        #expect(!removed.contains("🧭"))
        #expect(removed.contains("⚠️ Возможно, ошибка"))
    }

    @Test func removingSelectedKeepsOthers() {
        let found = Enrichment.additions(in: Self.enriched)
        let plotIndex = found.firstIndex { $0.kind == .plot }!
        let result = Enrichment.removing([plotIndex], from: Self.enriched)
        #expect(!result.contains("```plot"))
        #expect(result.contains("💡 Пояснение"))
        #expect(result.contains("🧭 Главное"))
        #expect(Enrichment.preservesAuthorText(original: Self.base, enriched: result))
    }

    @Test func otherCodeBlocksAreAuthorText() {
        let text = "Код:\n\n```python\nprint(1)\n```\n\n> 💡 Пояснение: ок."
        #expect(Enrichment.additions(in: text).map(\.kind) == [.explanation])
        #expect(Enrichment.removing(from: text).contains("print(1)"))
    }

    @Test func verificationAnswerIsParsedAndBounded() {
        let json = Data(#"{"problems":[{"id":2,"issue":"неверный пример"},{"id":99,"issue":"?"},{"id":0,"issue":"?"}]}"#.utf8)
        #expect(Enrichment.parseProblems(json, count: 4) == [Enrichment.Problem(id: 2, issue: "неверный пример")])
        #expect(Enrichment.parseProblems(Data("не json".utf8), count: 4) == nil)
        #expect(Enrichment.parseProblems(Data(#"{"problems":[]}"#.utf8), count: 4) == [])
    }
}

@Suite("EngineRouter: требуемый движок")
struct RequiredEngineTests {
    @Test func localPrimaryIsRefusedForClaudeOnlyRequest() async {
        let local = EngineRouterTests.FakeEngine([.success("не должен")], id: .ollama)
        let router = EngineRouter(primary: local, fallback: nil, settings: .init())
        var request = AIRequest(prompt: "p", systemPrompt: "s")
        request.requiredEngine = .claude
        await #expect(throws: AIError.self) { try await router.run(request) }
        #expect(await local.calls == 0)
    }

    @Test func claudeOnlyRequestDoesNotFallBackOnLimit() async {
        let limit = AIError.rateLimited(resetAt: nil, details: "limit")
        let claude = EngineRouterTests.FakeEngine([.failure(limit)])
        let local = EngineRouterTests.FakeEngine([.success("не должен")], id: .ollama)
        let router = EngineRouter(primary: claude, fallback: local, settings: .init())
        var request = AIRequest(prompt: "p", systemPrompt: "s")
        request.requiredEngine = .claude
        await #expect(throws: limit) { try await router.run(request) }
        #expect(await local.calls == 0)
    }
}
