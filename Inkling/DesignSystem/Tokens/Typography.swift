import AppKit
import SwiftUI

/// Шрифтовые роли. Интерфейс набирается SF, тексты для чтения — New York (`design: .serif`).
/// Обычные `.body`, `.callout`, `.caption`, `.headline` остаются системными и отдельных имён не получают.
extension Font {
    /// Заголовок листа или крупного состояния («Карточки для Anki», «Тест: 12 вопросов»).
    static let screenTitle = Font.title2.weight(.semibold)
    /// Заголовок раздела внутри экрана («Кратко», «Вопросы (14)»).
    static let sectionTitle = Font.title3.weight(.semibold)
    /// Служебная строка: происхождение конспекта, счётчики, статус.
    static let meta = Font.callout
    /// Подпись над содержимым («Ответ», «Решение»).
    static let label = Font.caption.weight(.semibold)
    /// Технические подробности ошибки, исходный текст в истории версий.
    static let mono = Font.caption.monospaced()

    /// Текст для чтения: вопросы, ответы, термины (`large` — вопрос теста, лицевая сторона карточки).
    /// Кегль берётся у системного стиля (`title3` и `title2`) и умножается на масштаб «Вид → Крупнее/Мельче»:
    /// на macOS нет системного Dynamic Type, `dynamicTypeSize` шрифты не меняет. В `body` вызывайте
    /// `.readingFont()`, он берёт масштаб из окружения.
    static func reading(scale: Double, large: Bool = false) -> Font {
        .system(size: readingPointSize(scale: scale, large: large), design: .serif)
    }

    /// Тот же кегль для веб-фрагментов с формулами (`snippet.html`).
    static func readingPointSize(scale: Double, large: Bool) -> CGFloat {
        NSFont.preferredFont(forTextStyle: large ? .title2 : .title3).pointSize * scale
    }

    /// Крупный символ начального экрана теста и карточек (с `.imageScale(.large)`).
    static let illustration = Font.largeTitle

    /// Итоговые числа: счёт теста, «Знаю 12 из 20».
    static let metric = Font.system(.largeTitle, design: .rounded).weight(.bold).monospacedDigit()
}

/// Масштаб текста для чтения: шаги команд «Крупнее» (⌘+) и «Мельче» (⌘−), хранится в `UserDefaults`.
enum ReadingScale {
    static let key = "reading.scale"
    static let steps: [Double] = [0.85, 1, 1.15, 1.3, 1.5, 1.75, 2]

    static func larger(_ scale: Double) -> Double { steps.first { $0 > scale + 0.001 } ?? scale }
    static func smaller(_ scale: Double) -> Double { steps.last { $0 < scale - 0.001 } ?? scale }
}

extension EnvironmentValues {
    @Entry var readingScale: Double = 1
}

private struct ReadingFont: ViewModifier {
    @Environment(\.readingScale) private var scale
    let large: Bool

    func body(content: Content) -> some View {
        content.font(.reading(scale: scale, large: large))
    }
}

extension View {
    /// Шрифт для чтения с масштабом из окружения.
    func readingFont(large: Bool = false) -> some View {
        modifier(ReadingFont(large: large))
    }
}
