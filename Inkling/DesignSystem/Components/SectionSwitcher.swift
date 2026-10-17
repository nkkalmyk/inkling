import SwiftUI

/// Переключатель разделов и режимов («Вопросы · Тест · Карточки», «Просмотр · Правка») в виде тулбарного
/// «Источники · Конспект · Самопроверка»: капсула и нейтральная заливка выбранного сегмента.
/// Акцентная заливка остаётся у действий; навигация её не берёт, иначе рядом с тулбаром выглядит
/// другим контролом. Переключатели значений в формах (настройки, редактор) остаются системными.
extension View {
    func sectionSwitcher(_ size: SectionSwitcherSize = .primary) -> some View {
        pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(size == .primary ? .large : .regular)
            .tint(.selectionNeutral)
    }
}

enum SectionSwitcherSize {
    /// Вторая ступень навигации под тулбаром, той же высоты, что и переключатель в тулбаре.
    case primary
    /// Режим внутри строки экрана рядом с обычными кнопками.
    case inline
}

#if DEBUG
#Preview("Переключатели разделов") {
    @Previewable @State var mode = 0
    @Previewable @State var editing = false
    ThemePair {
        VStack(spacing: Spacing.l) {
            Picker("Режим", selection: $mode) {
                Text("Вопросы").tag(0)
                Text("Тест").tag(1)
                Text("Карточки").tag(2)
            }
            .sectionSwitcher()
            Picker("Режим", selection: $editing) {
                Text("Просмотр").tag(false)
                Text("Правка").tag(true)
            }
            .sectionSwitcher(.inline)
        }
        .padding(Spacing.l)
    }
}
#endif
