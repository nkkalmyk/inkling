import SwiftUI

/// Подложка под содержимым. Поверхности различаются тоном, а не рамкой или тенью.
enum SurfaceKind {
    /// Карточка на фоне окна.
    case raised
    /// Утопленная подложка под картинками.
    case sunken
    /// Фон зоны самопроверки.
    case study
    /// Карточка в зоне самопроверки.
    case studyRaised

    var fill: Color {
        switch self {
        case .raised: .surfaceRaised
        case .sunken: .surfaceSunken
        case .study: .surfaceStudy
        case .studyRaised: .surfaceStudyRaised
        }
    }
}

extension View {
    /// Подложка с непрерывным скруглением: `.surface(.raised)`.
    func surface(_ kind: SurfaceKind, radius: CGFloat = Radius.card) -> some View {
        background(kind.fill, in: RoundedRectangle.ds(radius))
    }
}

#if DEBUG
#Preview("Поверхности") {
    ThemePair {
        VStack(spacing: Spacing.m) {
            ForEach([("raised", SurfaceKind.raised), ("sunken", .sunken)], id: \.0) { name, kind in
                Text(name).frame(maxWidth: .infinity, minHeight: 44).surface(kind)
            }
            VStack(spacing: Spacing.m) {
                Text("studyRaised").frame(maxWidth: .infinity, minHeight: 44).surface(.studyRaised)
            }
            .padding(Spacing.m)
            .surface(.study)
        }
    }
    .frame(width: 520)
}
#endif
