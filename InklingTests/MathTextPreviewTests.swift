import Foundation
import Testing
@testable import Inkling

@MainActor
struct MathTextPreviewTests {
    private func preview(_ text: String) -> String { String(MathText.preview(text).characters) }

    @Test func simpleFormulasLoseDollars() {
        #expect(preview("Какие размеры должны иметь матрицы $A$ и $B$?") == "Какие размеры должны иметь матрицы A и B?")
    }

    @Test func indicesAndBracesAreDropped() {
        #expect(preview("Свойство $(AB)^T$ и $a_{ij}$") == "Свойство (AB)T и aij")
    }

    @Test func commandsBecomeEllipsis() {
        #expect(preview("Почему $\\langle M_n(P), +\\rangle$ не поле?") == "Почему … не поле?")
    }

    @Test func displayFormulasAndNewlines() {
        #expect(preview("Вычислите\n$$\\det A$$") == "Вычислите …")
    }
}
