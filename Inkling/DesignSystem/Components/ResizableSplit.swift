import SwiftUI

/// Две колонки с перетаскиваемым разделителем. Вместо `HSplitView` там, где колонки начинаются
/// у верхнего края окна: в macOS 26 разделитель `HSplitView` продлевается в тулбар и прочерчивает
/// линию через его элементы. Обычный `Divider` остаётся в своих границах.
struct ResizableSplit<Leading: View, Trailing: View>: View {
    /// Ширина левой колонки; хранится у вызывающего (например, в `@AppStorage`).
    @Binding var leadingWidth: Double
    let range: ClosedRange<Double>
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    @State private var dragStart: Double?

    private var width: Double { min(max(leadingWidth, range.lowerBound), range.upperBound) }

    var body: some View {
        HStack(spacing: 0) {
            leading()
                .frame(width: width)
            Divider()
                .overlay {
                    Color.clear
                        .frame(width: 9)
                        .contentShape(Rectangle())
                        .pointerStyle(.columnResize)
                        .gesture(resize)
                }
                .accessibilityElement()
                .accessibilityLabel("Граница колонок")
                .accessibilityValue("\(Int(width)) пунктов")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: leadingWidth = min(width + 20, range.upperBound)
                    case .decrement: leadingWidth = max(width - 20, range.lowerBound)
                    @unknown default: break
                    }
                }
            trailing()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var resize: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let start = dragStart ?? width
                dragStart = start
                leadingWidth = min(max(start + value.translation.width, range.lowerBound), range.upperBound)
            }
            .onEnded { _ in dragStart = nil }
    }
}

#if DEBUG
#Preview("Колонки") {
    @Previewable @State var width = 220.0
    ThemePair {
        ResizableSplit(leadingWidth: $width, range: 160...320) {
            Text("Лента").frame(maxWidth: .infinity, maxHeight: .infinity).surface(.sunken, radius: 0)
        } trailing: {
            Text("Страница")
        }
    }
    .frame(width: 900, height: 300)
}
#endif
