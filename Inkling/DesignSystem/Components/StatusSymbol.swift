import SwiftUI

/// Значок состояния с обязательной подписью: она уходит в подсказку и в VoiceOver,
/// так что состояние не передаётся одним цветом или формой значка.
struct StatusSymbol: View {
    let systemImage: String
    let label: String
    var tint: Color = .statusNeutral
    /// Поверх картинки: значок на круглом материале.
    var onImage = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.caption)
            .foregroundStyle(tint)
            .padding(onImage ? 3 : 0)
            .background {
                if onImage { Circle().fill(.regularMaterial) }
            }
            .help(label)
            .accessibilityLabel(label)
    }
}

#if DEBUG
#Preview("Значки состояния") {
    ThemePair {
        HStack(spacing: Spacing.m) {
            StatusSymbol(systemImage: "clock", label: "В очереди")
            StatusSymbol(systemImage: "text.badge.xmark", label: "Не распознано")
            StatusSymbol(systemImage: "pencil.circle.fill", label: "Текст правлен вручную", tint: .accentColor)
            StatusSymbol(systemImage: "exclamationmark.triangle.fill", label: "Ошибка распознавания", tint: .statusError)
            StatusSymbol(systemImage: "clock", label: "В очереди", onImage: true)
                .padding(Spacing.s)
                .background(Color.gray)
        }
    }
    .frame(width: 520)
}
#endif
