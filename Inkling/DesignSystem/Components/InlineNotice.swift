import SwiftUI

/// Сообщение в шапке экрана: «Устарело», ошибка сборки, дата изменена по фото.
/// Одно на все экраны вместо цветных полос. Цвет есть только у ошибки; остальное различается значком и словами.
struct InlineNotice<Actions: View>: View {
    enum Kind {
        /// Сведения и предупреждения: «Устарело», «Дата изменена по фото».
        case info
        /// То, что легко пропустить, а пропускать нельзя: «Сделано локальной моделью — проверьте».
        case attention
        /// Ошибка: работа не выполнена.
        case error
    }

    let kind: Kind
    let message: String
    let systemImage: String
    var details: String?
    var dismiss: (() -> Void)?
    @ViewBuilder let actions: () -> Actions

    @State private var showDetails = false

    init(_ kind: Kind, _ message: String, systemImage: String, details: String? = nil,
         dismiss: (() -> Void)? = nil, @ViewBuilder actions: @escaping () -> Actions) {
        self.kind = kind
        self.message = message
        self.systemImage = systemImage
        self.details = details
        self.dismiss = dismiss
        self.actions = actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Image(systemName: systemImage)
                    .foregroundStyle(iconStyle)
                    .accessibilityHidden(true)
                Text(message)
                    .fontWeight(kind == .attention ? .semibold : nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(accessibilityPrefix + message)
                Spacer(minLength: Spacing.s)
                actions()
                if let dismiss {
                    IconButton("Закрыть", systemImage: "xmark", action: dismiss)
                }
            }
            if let details, !details.isEmpty {
                DisclosureGroup("Подробности", isExpanded: $showDetails) {
                    Text(details)
                        .font(.mono)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
        .font(.meta)
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .background(background)
        .accessibilityElement(children: .contain)
    }

    private var iconStyle: Color {
        switch kind {
        case .info: .statusNeutral
        case .attention: .primary
        case .error: .statusError
        }
    }

    private var background: Color {
        switch kind {
        case .info: .clear
        case .attention: .surfaceRaised
        case .error: .statusError.opacity(0.08)
        }
    }

    private var accessibilityPrefix: String {
        switch kind {
        case .info: ""
        case .attention: "Внимание: "
        case .error: "Ошибка: "
        }
    }
}

extension InlineNotice where Actions == EmptyView {
    init(_ kind: Kind, _ message: String, systemImage: String, details: String? = nil, dismiss: (() -> Void)? = nil) {
        self.init(kind, message, systemImage: systemImage, details: details, dismiss: dismiss) { EmptyView() }
    }
}

extension AnyTransition {
    /// Появление уведомления в шапке: выдвигается сверху, при «Уменьшить движение» только растворяется.
    static func notice(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }
}

#if DEBUG
#Preview("Уведомления") {
    ThemePair {
        VStack(spacing: 0) {
            InlineNotice(.info, "Устарело: тексты или порядок страниц изменились после сборки.",
                         systemImage: "clock.arrow.circlepath") {
                Button("Пересобрать") {}
            }
            Divider()
            InlineNotice(.attention, "Сделано локальной моделью — проверьте",
                         systemImage: "exclamationmark.triangle")
            Divider()
            InlineNotice(.error, "Конспект не собран. Превышен лимит запросов.",
                         systemImage: "exclamationmark.octagon.fill",
                         details: "claude: exit 1\nrate_limit_error: try again in 5h", dismiss: {}) {
                Button("Повторить") {}
            }
        }
    }
    .frame(width: 900)
}
#endif
