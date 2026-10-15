import SwiftUI

/// История версий конспекта, материалов или текста страницы: список слева, исходный текст справа, «Восстановить».
struct HistoryPopover: View {
    let entries: [HistoryStore.Entry]
    /// Почему список пуст: «Они появляются, когда конспект перезаписывается».
    let emptyHint: String
    /// Вторая строка версии: модель, режим, «правлено вручную».
    let subtitle: (HistoryStore.Entry) -> String
    var load: (HistoryStore.Entry) -> String = { (try? String(contentsOf: $0.file, encoding: .utf8)) ?? "" }
    let restore: (HistoryStore.Entry) -> Void

    @State private var selection: HistoryStore.Entry.ID?
    @State private var text = ""

    private var selected: HistoryStore.Entry? { entries.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("История версий").font(.headline)
            if entries.isEmpty {
                Text("Предыдущих версий нет. \(emptyHint)")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 320, alignment: .leading)
            } else {
                HStack(alignment: .top, spacing: Spacing.m) {
                    List(entries, selection: $selection) { entry in
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text(entry.date.preciseStamp)
                            Text(subtitle(entry)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 240, height: 300)
                    preview
                        .frame(width: 380, height: 300)
                        .surface(.sunken, radius: Radius.control)
                }
                .onChange(of: selection) { text = selected.map(load) ?? "" }
                HStack {
                    Spacer()
                    Button("Восстановить эту версию") { if let selected { restore(selected) } }
                        .disabled(selected == nil)
                }
            }
        }
        .padding(Spacing.l)
    }

    @ViewBuilder
    private var preview: some View {
        if selected != nil {
            ScrollView {
                Text(text)
                    .font(.mono)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.s)
            }
        } else {
            Text("Выберите версию слева")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

#if DEBUG
#Preview("История версий") {
    let entries = (1...3).map { index in
        HistoryStore.Entry(file: URL(filePath: "/tmp/version-\(index).md"),
                           date: .now.addingTimeInterval(Double(-index) * 3600))
    }
    ThemePair {
        VStack {
            HistoryPopover(entries: entries, emptyHint: "", subtitle: { _ in "sonnet · по частям" },
                           load: { "# Лекция\n\nВерсия от \($0.date.preciseStamp)" }, restore: { _ in })
            HistoryPopover(entries: [], emptyHint: "Они появляются, когда конспект перезаписывается.",
                           subtitle: { _ in "" }, restore: { _ in })
        }
    }
    .frame(width: 1400, height: 520)
}
#endif
