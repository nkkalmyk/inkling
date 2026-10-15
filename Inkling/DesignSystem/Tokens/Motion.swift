import SwiftUI

/// Движение. Пружины без отскока: они прерываемы и продолжают движение с текущей скорости.
/// Отскок только там, где перед ним был жест с инерцией; при «Уменьшить движение» — короткое растворение.
enum Motion {
    /// Смена состояний: появление уведомления, раскрытие ответа, перестройка раскладки.
    case standard
    /// Отклик на нажатие и выбор: подсветка варианта ответа, нажатая кнопка.
    case snappy
    /// Переворот и уход флеш-карточки.
    case card

    func animation(reduceMotion: Bool) -> Animation {
        guard !reduceMotion else { return .easeInOut(duration: 0.15) }
        return switch self {
        case .standard: .spring(duration: 0.35, bounce: 0)
        case .snappy: .spring(duration: 0.2, bounce: 0)
        case .card: .spring(duration: 0.45, bounce: 0)
        }
    }
}

extension View {
    /// `.animation(_:value:)` с учётом «Уменьшить движение».
    func motion(_ motion: Motion, value: some Equatable) -> some View {
        modifier(MotionModifier(motion: motion, value: value))
    }
}

private struct MotionModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let motion: Motion
    let value: Value

    func body(content: Content) -> some View {
        content.animation(motion.animation(reduceMotion: reduceMotion), value: value)
    }
}

/// `withAnimation` с учётом «Уменьшить движение»; `reduceMotion` берётся из окружения вызывающего view.
func withMotion<Result>(_ motion: Motion, reduceMotion: Bool, _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(motion.animation(reduceMotion: reduceMotion), body)
}
