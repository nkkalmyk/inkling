import SwiftUI

/// Идущая работа над лекцией: распознавание, сборка конспекта, подготовка материалов.
struct Activity: Identifiable {
    let id: String
    /// «Распознавание», «Сборка конспекта».
    var title: String
    /// «12 из 30 · Claude».
    var detail: String?
    /// Доля готового от 0 до 1; `nil` — сколько осталось, неизвестно.
    var fraction: Double?
    var startedAt: Date
    /// Примечание движка: «лимит Claude, перешли на локальную модель».
    var note: String?
    var cancel: (() -> Void)?
}

/// Индикатор активности для тулбара, как в Xcode: компактная строка, по щелчку — подробности и отмена.
/// Когда ничего не идёт, ничего и не показывает.
struct ActivityIndicator: View {
    let activities: [Activity]
    @State private var showDetails = false

    var body: some View {
        if let first = activities.first {
            Button {
                showDetails.toggle()
            } label: {
                HStack(spacing: Spacing.s) {
                    progress(first.fraction)
                        .controlSize(.small)
                    Text(activities.count == 1 ? first.title : "Задач: \(activities.count)")
                    if activities.count == 1 {
                        ElapsedText(since: first.startedAt)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.meta)
            }
            .help("Что сейчас выполняется")
            .accessibilityLabel(accessibilityLabel)
            .popover(isPresented: $showDetails, arrowEdge: .bottom) {
                ActivityList(activities: activities)
            }
        }
    }

    @ViewBuilder
    private func progress(_ fraction: Double?) -> some View {
        if let fraction {
            ProgressView(value: fraction).progressViewStyle(.circular)
        } else {
            ProgressView().progressViewStyle(.circular)
        }
    }

    private var accessibilityLabel: String {
        "Выполняется: " + activities.map { [$0.title, $0.detail].compactMap { $0 }.joined(separator: ", ") }
            .joined(separator: "; ")
    }
}

private struct ActivityList: View {
    let activities: [Activity]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            ForEach(activities) { activity in
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(activity.title).font(.headline)
                        Spacer()
                        ElapsedText(since: activity.startedAt).foregroundStyle(.secondary)
                    }
                    if let fraction = activity.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        if let detail = activity.detail {
                            Text(detail).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let cancel = activity.cancel {
                            Button("Отменить", action: cancel)
                        }
                    }
                    if let note = activity.note {
                        Text(note)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.meta)
            }
        }
        .padding(Spacing.l)
        .frame(width: 320)
    }
}

/// Сколько прошло с начала, обновляется раз в секунду: «3:07».
struct ElapsedText: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Duration.seconds(max(0, context.date.timeIntervalSince(since))).elapsed)
                .monospacedDigit()
        }
    }
}

#if DEBUG
@MainActor private let previewActivities = [
    Activity(id: "recognition", title: "Распознавание", detail: "12 из 30 · Claude", fraction: 0.4,
             startedAt: .now.addingTimeInterval(-187), cancel: {}),
    Activity(id: "study", title: "Подготовка материалов", detail: "Локальная модель",
             startedAt: .now.addingTimeInterval(-42), note: "Лимит Claude: перешли на локальную модель.", cancel: {}),
]

#Preview("Активность") {
    ThemePair {
        VStack(alignment: .leading, spacing: Spacing.l) {
            ActivityIndicator(activities: Array(previewActivities.prefix(1)))
            ActivityIndicator(activities: previewActivities)
            ActivityList(activities: previewActivities)
                .surface(.raised)
        }
    }
    .frame(width: 800)
}
#endif
