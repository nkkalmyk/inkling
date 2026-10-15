import SwiftUI

/// Итог теста или карточек: кольцо заполняется до доли верных ответов, в центре счёт.
struct ScoreRing: View {
    let score: Int
    let total: Int
    var diameter: CGFloat = 140

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Double = 0

    private var fraction: Double { total > 0 ? Double(score) / Double(total) : 0 }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.accentColor.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: shown)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(score)").font(.metric)
                Text("из \(total)").font(.meta).foregroundStyle(.secondary)
            }
        }
        .frame(width: diameter, height: diameter)
        .onAppear {
            withMotion(.card, reduceMotion: reduceMotion) { shown = fraction }
        }
        .onChange(of: fraction) {
            withMotion(.standard, reduceMotion: reduceMotion) { shown = fraction }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Результат: \(score) из \(total)")
    }

    private var lineWidth: CGFloat { diameter * 0.08 }
}

#if DEBUG
#Preview("Кольцо результата") {
    ThemePair {
        HStack(spacing: Spacing.xxl) {
            ScoreRing(score: 8, total: 10)
            ScoreRing(score: 20, total: 20, diameter: 100)
            ScoreRing(score: 0, total: 12, diameter: 100)
        }
    }
    .frame(width: 900, height: 220)
}
#endif
