import SwiftUI

/// Кнопка-значок без рамки: «Изменить», «Закрыть», флажок. Название обязательно:
/// оно видно в подсказке и читается VoiceOver, хотя на экране только значок.
struct IconButton: View {
    let title: String
    let systemImage: String
    var help: String?
    let action: () -> Void

    init(_ title: String, systemImage: String, help: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help(help ?? title)
    }
}

#if DEBUG
#Preview("Кнопки-значки") {
    ThemePair {
        HStack(spacing: Spacing.m) {
            IconButton("Изменить вопрос", systemImage: "pencil") {}
            IconButton("Ошибка в вопросе", systemImage: "flag") {}
            IconButton("Закрыть", systemImage: "xmark") {}
        }
    }
    .frame(width: 320)
}
#endif
