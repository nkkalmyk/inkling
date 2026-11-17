import Foundation
import Testing
@testable import Inkling

@MainActor
struct MathTextPreviewTests {
    private func preview(_ text: String) -> String { String(MathText.preview(text).characters) }

    @Test func simpleFormulasLoseDollars() {
        #expect(preview("Какие размеры должны иметь матрицы $A$ и $B$?") == "Какие размеры должны иметь матрицы A и B?")
    }

    @Test func indicesAndPowersBecomeUnicode() {
        #expect(preview("Свойство $(AB)^T$ и $a_{ij}$") == "Свойство (AB)ᵀ и aij")
        #expect(preview("Как определяется $c_{ij}$ произведения $AB=C$?") == "Как определяется cij произведения AB=C?")
        #expect(preview("Докажите $|A|=|A^T|$.") == "Докажите |A|=|Aᵀ|.")
        #expect(preview("Последовательность $x_n$ и $a_{k+1}$") == "Последовательность xₙ и aₖ₊₁")
    }

    @Test func commandsBecomeSymbols() {
        #expect(preview("Почему $\\langle M_n(P), +\\rangle$ не поле?") == "Почему ⟨Mₙ(P), +⟩ не поле?")
        #expect(preview("Почему $M_n(P)$ при $n\\ge 2$ не поле?") == "Почему Mₙ(P) при n ≥ 2 не поле?")
        #expect(preview("Пусть $A\\in M_3(P)$, найдите $\\det(3A)$") == "Пусть A ∈ M₃(P), найдите det(3A)")
        #expect(preview("Чему равен $\\det T_{23}(\\lambda)$?") == "Чему равен det T₂₃(λ)?")
        #expect(preview("Пусть $x \\to +\\infty$") == "Пусть x → +∞")
    }

    @Test func limitsAndFractions() {
        #expect(preview("Найдите $\\lim_{x \\to 0+0} \\frac{1}{x}$") == "Найдите lim(x→0+0) 1/x")
        #expect(preview("Докажите $\\lim_{x \\to a} f(x) = A$") == "Докажите lim(x→a) f(x) = A")
        #expect(preview("$\\lim_{x \\to 0} \\left|\\frac{1}{x}\\right|$") == "lim(x→0) |1/x|")
    }

    @Test func matricesAndUnknownCommandsBecomeEllipsis() {
        #expect(preview("Сложите $\\begin{pmatrix} 1 & 2 \\\\ 3 & 4 \\end{pmatrix}$ и $B$") == "Сложите … и B")
        #expect(preview("Что такое $\\widehat{x}$?") == "Что такое …?")
    }

    @Test func displayFormulasAndNewlines() {
        #expect(preview("Вычислите\n$$\\det A$$") == "Вычислите det A")
    }
}
