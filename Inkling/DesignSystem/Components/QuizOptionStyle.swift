import SwiftUI

/// Состояние варианта ответа в тесте.
enum QuizOptionState: Equatable {
    /// Ответа ещё нет.
    case idle
    /// Выбран и верен.
    case correct
    /// Выбран и неверен.
    case wrong
    /// Не выбран, но верен: показываем после ошибки.
    case missedCorrect
    /// Не выбран и неверен: после ответа уходит на второй план.
    case dimmed

    /// Правильность читается значком и словами, не только цветом.
    var symbol: String? {
        switch self {
        case .correct, .missedCorrect: "checkmark.circle.fill"
        case .wrong: "xmark.circle.fill"
        case .idle, .dimmed: nil
        }
    }

    var accessibilityValue: String {
        switch self {
        case .idle, .dimmed: ""
        case .correct: "Ваш ответ, верно"
        case .wrong: "Ваш ответ, неверно"
        case .missedCorrect: "Верный ответ"
        }
    }

    fileprivate var tint: Color? {
        switch self {
        case .correct, .missedCorrect: .statusSuccess
        case .wrong: .statusError
        case .idle, .dimmed: nil
        }
    }
}

/// Вариант ответа: широкая кнопка в тёплой карточке. После ответа подсвечивает верный и выбранный варианты.
struct QuizOptionStyle: ButtonStyle {
    let state: QuizOptionState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle.ds(Radius.control)
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
            if let symbol = state.symbol {
                Image(systemName: symbol)
                    .foregroundStyle(state.tint ?? .secondary)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    .accessibilityHidden(true)
            }
        }
        .padding(Spacing.m)
        .background(shape.fill(state.tint?.opacity(0.14) ?? Color.surfaceStudyRaised))
        .overlay(shape.strokeBorder(state.tint ?? .clear, lineWidth: 1.5))
        .opacity(state == .dimmed ? 0.55 : 1)
        .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
        .contentShape(shape)
        .animation(Motion.snappy.animation(reduceMotion: reduceMotion), value: configuration.isPressed)
        .animation(Motion.standard.animation(reduceMotion: reduceMotion), value: state)
        .accessibilityValue(state.accessibilityValue)
    }
}

#if DEBUG
#Preview("Варианты ответа") {
    let states: [(String, QuizOptionState)] = [
        ("Окислитель принимает электроны", .idle),
        ("Восстановитель принимает электроны", .wrong),
        ("Окислитель принимает электроны", .missedCorrect),
        ("Степень окисления не меняется", .dimmed),
        ("Верно выбранный ответ", .correct),
    ]
    ThemePair {
        VStack(spacing: Spacing.s) {
            ForEach(Array(states.enumerated()), id: \.offset) { index, item in
                Button {} label: {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                        Text("\(index + 1)").font(.headline.monospacedDigit()).foregroundStyle(.secondary)
                        Text(item.0).font(.reading)
                    }
                }
                .buttonStyle(QuizOptionStyle(state: item.1))
            }
        }
        .padding(Spacing.m)
        .surface(.study)
    }
    .frame(width: 900)
}
#endif
