import SwiftUI

/// Пустой экран: что здесь будет и как до этого дойти. Обёртка над `ContentUnavailableView`
/// с крупным многослойным символом; в зоне самопроверки символ в цвете акцента.
struct EmptyState<Actions: View>: View {
    let title: String
    let systemImage: String
    var description: String?
    var tint: Color = .secondary
    @ViewBuilder let actions: () -> Actions

    init(_ title: String, systemImage: String, description: String? = nil, tint: Color = .secondary,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.tint = tint
        self.actions = actions
    }

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
            }
        } description: {
            if let description { Text(description) }
        } actions: {
            actions()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Actions == EmptyView {
    init(_ title: String, systemImage: String, description: String? = nil, tint: Color = .secondary) {
        self.init(title, systemImage: systemImage, description: description, tint: tint) { EmptyView() }
    }
}

#if DEBUG
#Preview("Пустые состояния") {
    ThemePair {
        VStack {
            EmptyState("Конспекта пока нет", systemImage: "doc.richtext",
                       description: "Сначала добавьте и распознайте страницы на вкладке «Источники».")
            EmptyState("Учебных материалов пока нет", systemImage: "graduationcap",
                       description: "Вопросы, тест и карточки готовятся по конспекту.", tint: .accentColor) {
                Button("Подготовить материалы") {}.prominentAction()
            }
        }
    }
    .frame(width: 900, height: 560)
}
#endif
