#if DEBUG
import SwiftUI

/// Для `#Preview`: одно и то же содержимое в светлой и тёмной теме рядом.
struct ThemePair<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            pane(.light)
            pane(.dark)
        }
    }

    private func pane(_ scheme: ColorScheme) -> some View {
        content()
            .padding(Spacing.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
            .environment(\.colorScheme, scheme)
    }
}
#endif
