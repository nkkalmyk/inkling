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

    /// Текст для чтения: вопросы, ответы, термины.
    static let reading = Font.system(.body, design: .serif)
    /// Крупный текст для чтения: вопрос теста, лицевая сторона карточки.
    static let readingLarge = Font.system(.title3, design: .serif)

    /// Итоговые числа: счёт теста, «Знаю 12 из 20».
    static let metric = Font.system(.largeTitle, design: .rounded).weight(.bold).monospacedDigit()
}
