import AppKit
import SwiftUI

/// Семантические цвета. Имена говорят о роли, а не об оттенке: экранам не нужно знать, что акцент янтарный.
/// Светлая и тёмная темы, а также режим повышенного контраста заданы в `Assets.xcassets`
/// или берутся из системных цветов, которые адаптируются сами.
extension Color {
    // MARK: Акцент

    /// Текст и символы поверх акцентной заливки. В тёмной теме янтарь светлый, поэтому подпись на нём тёмная.
    static let onAccent = Color("OnAccent")

    // MARK: Поверхности

    /// Карточка на фоне окна: вопрос, раздел источников, подложка под содержимым.
    static let surfaceRaised = Color(nsColor: .quaternarySystemFill)
    /// Утопленная подложка: под миниатюрами и превью, где содержимое само даёт цвет.
    static let surfaceSunken = Color(nsColor: .quinarySystemFill)
    /// Тёплый фон зоны самопроверки (вопросы, тест, карточки).
    static let surfaceStudy = Color("StudySurface")
    /// Карточка внутри зоны самопроверки.
    static let surfaceStudyRaised = Color("StudySurfaceRaised")

    // MARK: Статусы

    /// Ошибка: единственный «тревожный» цвет интерфейса.
    static let statusError = Color.red
    /// Успех: верный ответ, всё распознано.
    static let statusSuccess = Color.green
    /// Предупреждения и сведения («устарело», «в очереди») цвета не получают.
    static let statusNeutral = Color.secondary
}
