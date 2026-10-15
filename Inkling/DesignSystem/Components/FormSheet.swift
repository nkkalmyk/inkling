import SwiftUI

/// Каркас листа с формой: заголовок, поля, ряд кнопок. Отмена — Esc, подтверждение — Return.
/// Лист закрывается сам, если `confirm` вернул `true`; при ошибке остаётся открытым.
struct FormSheet<Fields: View>: View {
    let title: String
    var subtitle: String?
    var width: CGFloat = SheetWidth.regular
    let confirmTitle: String
    var canConfirm = true
    /// Короткая форма подстраивает высоту под поля; длинная (редактор вопроса) прокручивается в заданной высоте.
    var fitsContent = true
    /// Необязательная разрушающая кнопка слева («Удалить»). Лист закрывается после неё.
    var destructive: (title: String, action: () -> Void)?
    let confirm: () -> Bool
    @ViewBuilder let fields: () -> Fields

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title).font(.screenTitle)
                if let subtitle {
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.xl)

            Form(content: fields)
                .formStyle(.grouped)
                .scrollBounceBehavior(.basedOnSize)
                .scrollDisabled(fitsContent)
                .fixedSize(horizontal: false, vertical: fitsContent)

            HStack {
                if let destructive {
                    Button(destructive.title, role: .destructive) {
                        destructive.action()
                        dismiss()
                    }
                }
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) { if confirm() { dismiss() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm)
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.xl)
        }
        .frame(width: width)
    }
}

#if DEBUG
#Preview("Лист с формой") {
    @Previewable @State var topic = "Окислительно-восстановительные реакции"
    @Previewable @State var date = Date()
    ThemePair {
        FormSheet(title: "Новая лекция", subtitle: "Фото конспекта и слайды добавляются внутри лекции.",
                  confirmTitle: "Создать", canConfirm: !topic.isEmpty, confirm: { true }) {
            Picker("Предмет", selection: .constant("Химия")) { Text("Химия").tag("Химия") }
            TextField("Тема", text: $topic)
            DatePicker("Дата", selection: $date, displayedComponents: .date)
        }
    }
    .frame(width: 1040, height: 380)
}
#endif
