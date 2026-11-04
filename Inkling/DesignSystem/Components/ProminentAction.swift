import SwiftUI

extension View {
    /// Главное действие экрана: акцентная кнопка. В активном окне подпись берёт цвет `onAccent`,
    /// потому что на светлом янтаре тёмной темы белый текст не читается. В неактивном окне
    /// система заливает кнопку серым, и подпись остаётся системной.
    func prominentAction() -> some View {
        modifier(ProminentAction())
    }

    /// Акцентная кнопка, только пока `isProminent`; иначе стиль по месту (в тулбаре — обычная кнопка).
    /// Для пары кнопок, между которыми переходит роль главной: на экране яркая всегда одна.
    @ViewBuilder
    func prominentAction(_ isProminent: Bool) -> some View {
        if isProminent { prominentAction() } else { self }
    }
}

private struct ProminentAction: ViewModifier {
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        if appearsActive && isEnabled {
            content.buttonStyle(.borderedProminent).foregroundStyle(Color.onAccent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

#if DEBUG
#Preview("Главное действие") {
    ThemePair {
        HStack(spacing: Spacing.m) {
            Button("Собрать конспект") {}.prominentAction()
            Button("Собрать конспект") {}.prominentAction().controlSize(.large)
            Button("Недоступно") {}.prominentAction().disabled(true)
            Button("Уступила роль") {}.prominentAction(false)
            Button("Отмена") {}
        }
    }
    .frame(width: 900)
}
#endif
