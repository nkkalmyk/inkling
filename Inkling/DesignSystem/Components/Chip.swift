import SwiftUI

/// Короткая метка: тип и сложность вопроса, «Оригинал» на миниатюре, «Ошибка в вопросе».
struct Chip: View {
    enum Style {
        /// Обычная метка в тексте.
        case neutral
        /// Выделенная метка: свойство, на которое стоит обратить внимание.
        case accent
        /// Ошибка.
        case error
        /// Поверх картинки: на материале, читается на любом фото.
        case overlay
    }

    let text: String
    var style: Style = .neutral

    init(_ text: String, style: Style = .neutral) {
        self.text = text
        self.style = style
    }

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xxs)
            .foregroundStyle(foreground)
            .background { background }
    }

    private var foreground: Color {
        switch style {
        case .neutral, .overlay: .primary
        case .accent: .accentColor
        case .error: .statusError
        }
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle.ds(Radius.chip)
        switch style {
        case .neutral: shape.fill(Color.surfaceRaised)
        case .accent: shape.fill(Color.accentColor.opacity(0.14))
        case .error: shape.fill(Color.statusError.opacity(0.12))
        case .overlay: shape.fill(.regularMaterial)
        }
    }
}

#if DEBUG
#Preview("Плашки") {
    ThemePair {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack {
                Chip("Определение")
                Chip("Сложный", style: .accent)
                Chip("Ошибка в вопросе", style: .error)
            }
            Chip("Оригинал", style: .overlay)
                .padding(Spacing.l)
                .background(LinearGradient(colors: [.blue, .orange], startPoint: .leading, endPoint: .trailing))
        }
    }
    .frame(width: 640)
}
#endif
