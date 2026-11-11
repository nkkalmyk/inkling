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

    @Test func removingAllRestoresBaseText() {
        let removed = Enrichment.removing(from: Self.enriched)
        #expect(Enrichment.additions(in: removed).isEmpty)
        #expect(Self.words(removed) == Self.words(Self.base))
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
    }

    @Test func otherCodeBlocksAreAuthorText() {
        let text = "Код:\n\n```python\nprint(1)\n```\n\n> 💡 Пояснение: ок."
        #expect(Enrichment.additions(in: text).map(\.kind) == [.explanation])
        #expect(Enrichment.removing(from: text).contains("print(1)"))
    }

    /// Авторский текст для сравнения: без `**` и с одинаковыми пробелами (выделение терминов — не правка автора).
    private static func words(_ markdown: String) -> String {
        markdown.replacingOccurrences(of: "**", with: "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
