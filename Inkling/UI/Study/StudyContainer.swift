import SwiftUI

struct LoadedStudyFiles {
    var materials: StudyMaterials?
    var progress: StudyProgress
}

/// Файлы самопроверки читаются в фоне: в iCloud Drive они могут быть выгружены из Mac, и чтение
/// на главном потоке ждало бы загрузки — окно замирало. Вне `StudyContainer`: обобщённый вид нельзя
/// передать в `@concurrent`-контекст.
@concurrent
func loadStudyFiles(_ store: StudyStore) async -> LoadedStudyFiles {
    LoadedStudyFiles(materials: store.readStudy(), progress: store.readProgress())
}

/// Общая обвязка вкладок «Вопросы», «Тест», «Карточки»: тёплый фон зоны, подготовка материалов,
/// «Устарело», ошибки.
struct StudyContainer<Content: View>: View {
    @Environment(StudyCenter.self) private var study
    let lecture: LectureRecord
    let showNotes: () -> Void
    @ViewBuilder let content: (StudyMaterials, StudyProgress) -> Content

    @State private var confirmRegenerate = false
    @Environment(\.lectureRequests) private var requests
    @Environment(\.isActiveTab) private var isActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Материалы и прогресс, прочитанные в фоне (`loadStudyFiles`). `nil` — ещё читаются.
    @State private var loaded: LoadedStudyFiles?

    /// Когда перечитывать файлы: перезапись материалов или прогресса и новые сведения о материалах.
    private struct LoadKey: Equatable {
        var revision: Int
        var study: ArtifactInfo?
    }

    var body: some View {
        let materials = loaded?.materials
        VStack(spacing: 0) {
            if !study.isRunning(lecture.id) {
                if let error = study.errors[lecture.id] {
                    InlineNotice(.error, "Материалы не подготовлены. \(error.userMessage)",
                                 systemImage: "exclamationmark.octagon.fill", details: error.details,
                                 dismiss: { study.errors[lecture.id] = nil }) {
                        if hasKonspekt { Button("Повторить") { study.generate(lecture.id) } }
                    }
                    .transition(.notice(reduceMotion: reduceMotion))
                    Divider()
                } else if materials != nil, study.knownStale(lecture) {
                    InlineNotice(.info, "Устарело: конспект изменился после подготовки материалов.",
                                 systemImage: "exclamationmark.arrow.circlepath") {
                        Button("Подготовить заново", action: regenerate)
                    }
                    .transition(.notice(reduceMotion: reduceMotion))
                    Divider()
                }
            }
            if let loaded {
                if let materials = loaded.materials {
                    content(materials, loaded.progress)
                } else {
                    emptyState
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surfaceStudy)
        .task(id: LoadKey(revision: study.revision(lecture.id), study: lecture.meta.study)) {
            let read = await loadStudyFiles(study.store(lecture))
            if !Task.isCancelled { loaded = read }
        }
        .motion(.standard, value: study.errors[lecture.id] == nil)
        .task(id: requests.wrappedValue.prepareStudy && isActive) {
            guard requests.wrappedValue.prepareStudy, isActive else { return }
            requests.wrappedValue.prepareStudy = false
            if materials == nil { study.generate(lecture.id) } else { regenerate() }
        }
        .confirmationDialog("Подготовить материалы заново?", isPresented: $confirmRegenerate) {
            Button("Подготовить") { study.generate(lecture.id) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Прогресс самопроверки начнётся заново. Старые материалы и прогресс сохранятся в истории"
                 + (lecture.meta.study?.manuallyEdited == true ? ", включая ваши правки." : "."))
        }
    }

    private var hasKonspekt: Bool { lecture.meta.konspekt != nil }

    func regenerate() {
        let progress = loaded?.progress ?? study.store(lecture).readProgress()
        if lecture.meta.study?.manuallyEdited == true || !progress.isEmpty { confirmRegenerate = true }
        else { study.generate(lecture.id) }
    }

    private var emptyState: some View {
        EmptyState(study.isRunning(lecture.id) ? "Материалы готовятся…" : "Учебных материалов пока нет",
                   systemImage: "graduationcap",
                   description: study.isRunning(lecture.id)
                       ? "Вопросы, тест и карточки появятся здесь; ход работы — в индикаторе на панели."
                       : hasKonspekt
                       ? "Вопросы, тест и карточки готовятся по конспекту. Проверьте конспект перед запуском, "
                           + "чтобы ошибки распознавания не попали в карточки."
                       : "Сначала соберите конспект на вкладке «Конспект».",
                   tint: .accentColor) {
            if hasKonspekt {
                Button("Подготовить материалы") { study.generate(lecture.id) }
                    .prominentAction()
                    .disabled(study.isRunning(lecture.id))
            } else {
                Button("Перейти к конспекту", action: showNotes)
            }
        }
    }
}

/// Единая полоса самопроверки под тулбаром: слева — чем и когда подготовлены материалы, по центру — режим
/// («Вопросы · Тест · Карточки»), справа — «Подготовить заново». Одна на три вкладки (лежит поверх них в `LectureView`),
/// вместо отдельных строк переключателя и источника.
struct StudyModeBar: View {
    @Environment(StudyCenter.self) private var study
    let lecture: LectureRecord
    @Binding var mode: LectureTab
    @State private var confirm = false

    var body: some View {
        // Стороны одинаково гибкие: переключатель остаётся ровно по центру, подпись обрезается на своей стороне.
        HStack(spacing: Spacing.m) {
            HStack(spacing: Spacing.s) {
                if let info = lecture.meta.study {
                    Text([info.model, info.updatedAt.stamp, info.manuallyEdited ? "правлено вручную" : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    ReviewBadge(engine: info.engine, manuallyEdited: info.manuallyEdited)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Picker("Режим", selection: $mode) {
                ForEach(LectureTab.studyTabs) { Text($0.title).tag($0) }
            }
            .sectionSwitcher()
            HStack {
                // Когда материалы устарели, «Подготовить заново» уже есть в уведомлении под полосой.
                if lecture.meta.study != nil, !study.knownStale(lecture) {
                    Button("Подготовить заново") {
                        let progress = study.store(lecture).readProgress()
                        if lecture.meta.study?.manuallyEdited == true || !progress.isEmpty { confirm = true }
                        else { study.generate(lecture.id) }
                    }
                    .disabled(study.isRunning(lecture.id))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.meta)
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .confirmationDialog("Подготовить материалы заново?", isPresented: $confirm) {
            Button("Подготовить") { study.generate(lecture.id) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Прогресс самопроверки начнётся заново. Старые материалы и прогресс сохранятся в истории.")
        }
    }
}

/// Флажок «ошибка в вопросе».
struct FlagButton: View {
    @Environment(StudyCenter.self) private var study
    let lectureID: UUID
    let itemID: String
    let flagged: Bool

    var body: some View {
        Button {
            study.updateProgress(lectureID) { progress in
                if flagged { progress.flagged.remove(itemID) } else { progress.flagged.insert(itemID) }
            }
        } label: {
            Label(flagged ? "Снять пометку «ошибка в вопросе»" : "Ошибка в вопросе",
                  systemImage: flagged ? "flag.fill" : "flag")
                .labelStyle(.iconOnly)
                .foregroundStyle(flagged ? Color.statusError : .secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .help(flagged ? "Снять пометку «ошибка в вопросе»" : "Ошибка в вопросе: не учитывать и не показывать в самопроверке")
    }
}

/// Начальный экран теста и карточек: крупный символ, счёт, кнопки, подсказка по клавишам.
struct StudyStart<Actions: View>: View {
    let systemImage: String
    let title: String
    var subtitle: String?
    let hint: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: Spacing.l) {
            Image(systemName: systemImage)
                .font(.illustration)
                .imageScale(.large)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(title).font(.screenTitle)
            if let subtitle {
                Text(subtitle).foregroundStyle(.secondary)
            }
            HStack(spacing: Spacing.m) { actions() }
                .controlSize(.large)
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
    }
}
