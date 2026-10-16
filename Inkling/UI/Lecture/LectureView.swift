import SwiftUI

/// Экран лекции: две зоны в тулбаре («Источники», «Конспект» и «Самопроверка»), следующий шаг
/// главной кнопкой, идущая работа — индикатором активности, сообщения — в шапке.
struct LectureView: View {
    @Environment(Library.self) private var library
    @Environment(RecognitionCenter.self) private var recognition
    @Environment(AssemblyCenter.self) private var assembly
    @Environment(StudyCenter.self) private var study
    @Environment(EnrichmentCenter.self) private var enrichment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let lecture: LectureRecord

    @State private var tab: LectureTab
    /// Вкладки, которые уже открывали: они не пересоздаются при переключении.
    @State private var visited: Set<LectureTab>
    @State private var lastStudyTab: LectureTab = .questions
    @State private var requests = LectureRequests()
    @State private var export: ExportController?

    init(lecture: LectureRecord, tab: LectureTab = .sources) {
        self.lecture = lecture
        _tab = State(initialValue: tab)
        _visited = State(initialValue: [tab])
    }

    /// Следующий шаг. Считается не в body (он читает тексты всех страниц), а при изменении лекции
    /// или её работ: иначе каждое переключение вкладки читало бы диск.
    @State private var primary: LecturePrimaryAction?

    /// От чего зависит следующий шаг.
    private struct PrimaryKey: Equatable {
        var meta: LectureMeta
        var busy: [Bool]
    }

    private var primaryKey: PrimaryKey {
        PrimaryKey(meta: lecture.meta, busy: [recognition.isBusy(lecture.id), assembly.isRunning(lecture.id),
                                              enrichment.isRunning(lecture.id), study.isRunning(lecture.id),
                                              study.errors[lecture.id] != nil])
    }

    var body: some View {
        VStack(spacing: 0) {
            notices
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: primaryKey, initial: true) {
            primary = LecturePrimaryAction.next(for: lecture, recognition: recognition, assembly: assembly,
                                                enrichment: enrichment, study: study)
        }
        .motion(.standard, value: lecture.hasConflict)
        .motion(.standard, value: lecture.meta.dateAdjustment)
        .navigationTitle(lecture.meta.topic)
        .navigationSubtitle("\(lecture.meta.subject) · \(lecture.meta.date.formatted)")
        .toolbar { toolbar }
        .environment(\.lectureRequests, $requests)
        .focusedSceneValue(\.lectureCommands, commands)
        .sheet(isPresented: Binding(get: { export?.askAnki ?? false }, set: { export?.askAnki = $0 })) {
            if let export { AnkiExportSheet(export: export) }
        }
        .onAppear { export = ExportController(library: library, lecture: lecture) }
        .onChange(of: lecture) { export?.update(lecture) }
        .task(id: lecture.id) { await prewarm() }
        .onChange(of: tab) {
            visited.insert(tab)
            if tab.isStudy { lastStudyTab = tab }
        }
    }

    // MARK: Шапка

    @ViewBuilder
    private var notices: some View {
        if lecture.hasConflict {
            InlineNotice(.info, "У этой лекции есть конфликтные копии iCloud. Приложение не перезаписывает их само: "
                         + "проверьте файлы в Finder.", systemImage: "exclamationmark.icloud") {
                Button("Показать в Finder") { library.revealInFinder(lecture.folder) }
            }
            .transition(.notice(reduceMotion: reduceMotion))
            Divider()
        }
        if let adjustment = lecture.meta.dateAdjustment {
            InlineNotice(.info, "Дата изменена по фото: \(lecture.meta.date.formatted) "
                         + "(было \(adjustment.previousDate.formatted)).",
                         systemImage: "calendar.badge.clock",
                         dismiss: { library.acceptDateAdjustment(lectureID: lecture.id) }) {
                Button("Вернуть") { library.revertDateAdjustment(lectureID: lecture.id) }
            }
            .transition(.notice(reduceMotion: reduceMotion))
            Divider()
        }
    }

    /// Режимы самопроверки: вторая ступень навигации внутри тёплой зоны.
    private var studyModePicker: some View {
        Picker("Режим", selection: $tab) {
            ForEach(LectureTab.studyTabs) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .padding(.vertical, Spacing.s)
        .frame(maxWidth: .infinity)
        .background(Color.surfaceStudy)
    }

    /// Открытые вкладки живут каждая в своём хост-виде, видна одна (`KeptAliveTabs`). Повторное
    /// переключение — смена видимости, а не сборка экрана заново.
    private var content: some View {
        KeptAliveTabs(tabs: LectureTab.allCases.filter(visited.contains), active: tab, revision: lecture) { item in
            tabContent(item)
        }
    }

    /// Через полсекунды после открытия лекции скрыто строит конспект и вопросы, если они есть:
    /// тогда и первое переключение на них мгновенное, а цена сборки приходится на паузу.
    private func prewarm() async {
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }
        if lecture.meta.konspekt != nil { visited.insert(.notes) }
        if lecture.meta.study != nil { visited.insert(lastStudyTab) }
    }

    /// Вкладки самопроверки несут свой переключатель режима: высота общей области при переходе
    /// между зонами не меняется, и скрытые вкладки не раскладываются заново.
    @ViewBuilder
    private func tabContent(_ item: LectureTab) -> some View {
        if item.isStudy {
            VStack(spacing: 0) {
                studyModePicker
                screen(item)
            }
        } else {
            screen(item)
        }
    }

    @ViewBuilder
    private func screen(_ item: LectureTab) -> some View {
        switch item {
        case .sources:
            SourcesView(lecture: lecture)
        case .notes:
            NotesView(lecture: lecture)
        case .questions:
            QuestionsView(lecture: lecture, showNotes: { tab = .notes })
        case .quiz:
            QuizView(lecture: lecture, showNotes: { tab = .notes })
        case .flashcards:
            FlashcardsView(lecture: lecture, showNotes: { tab = .notes })
        }
    }

    // MARK: Тулбар

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Раздел", selection: zoneBinding) {
                ForEach(LectureZoneItem.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        ToolbarItem {
            LectureActivityIndicator(lecture: lecture, exportingPDFSince: export?.exportingPDFSince)
        }
        if let primary {
            ToolbarItem {
                Button { perform(primary) } label: {
                    Label(primary.title, systemImage: primary.systemImage)
                        .labelStyle(.titleAndIcon)
                }
                .prominentAction()
                .help("Следующий шаг (⌘↩)")
            }
        }
        ToolbarItem {
            EngineModeMenu()
        }
        ToolbarItem {
            Menu {
                if let export { ExportMenuItems(export: export) }
                Divider()
                Button("Изменить лекцию…") { library.sheet = .editLecture(lecture.id) }
                Button("Показать в Finder") { library.revealInFinder(lecture.folder) }
            } label: {
                Label("Ещё", systemImage: "ellipsis")
            }
            .help("Экспорт, изменение лекции")
        }
    }

    private var zoneBinding: Binding<LectureZoneItem> {
        Binding(get: { LectureZoneItem(tab) }, set: { item in
            switch item {
            case .sources: tab = .sources
            case .notes: tab = .notes
            case .study: tab = lastStudyTab
            }
        })
    }

    private func perform(_ action: LecturePrimaryAction) {
        switch action {
        case .recognize(let pages):
            recognition.recognize(lectureID: lecture.id, pageIDs: pages)
        case .assemble:
            tab = .notes
            requests.assemble = true
        case .prepareStudy:
            if !tab.isStudy { tab = lastStudyTab }
            requests.prepareStudy = true
        }
    }

    /// «Дополнить» доступно, когда конспект есть и по лекции ничего не идёт.
    private var canEnrich: Bool {
        let id = lecture.id
        return lecture.meta.konspekt != nil && !recognition.isBusy(id) && !assembly.isRunning(id)
            && !enrichment.isRunning(id)
    }

    private var commands: LectureCommands {
        LectureCommands(
            tab: $tab, primary: primary, perform: perform,
            enrich: canEnrich ? { tab = .notes; requests.enrich = true } : nil,
            exportMarkdown: export?.hasKonspekt == true ? { export?.exportMarkdown() } : nil,
            exportPDF: export?.hasKonspekt == true && export?.exportingPDFSince == nil ? { export?.exportPDF() } : nil,
            exportAnki: export?.hasStudy == true ? { export?.askAnki = true } : nil,
            edit: { library.sheet = .editLecture(lecture.id) },
            reveal: { library.revealInFinder(lecture.folder) })
    }
}
