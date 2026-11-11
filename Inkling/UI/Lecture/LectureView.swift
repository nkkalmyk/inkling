import SwiftUI

/// Экран лекции: две зоны в тулбаре («Источники», «Конспект» и «Самопроверка»), следующий шаг
/// главной кнопкой, идущая работа — индикатором активности, сообщения — в шапке.
struct LectureView: View {
    @Environment(Library.self) private var library
    @Environment(RecognitionCenter.self) private var recognition
    @Environment(AssemblyCenter.self) private var assembly
    @Environment(StudyCenter.self) private var study
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let lecture: LectureRecord

    @State private var tab: LectureTab
    /// Вкладки, которые уже открывали: они не пересоздаются при переключении.
    @State private var visited: Set<LectureTab>
    @State private var lastStudyTab: LectureTab = .questions
    @State private var requests = LectureRequests()
    @State private var export: ExportController?
    @State private var notesFlush = NotesFlush()

    init(lecture: LectureRecord, tab: LectureTab = .sources) {
        self.lecture = lecture
        _tab = State(initialValue: tab)
        _visited = State(initialValue: [tab])
    }

    /// Следующий шаг. Считается при изменении лекции, её работ или фоновых сводок по текстам
    /// (`knownReadiness`, `knownStale`), а не в каждом body.
    @State private var primary: LecturePrimaryAction?

    /// От чего зависит следующий шаг.
    private struct PrimaryKey: Equatable {
        var meta: LectureMeta
        var busy: [Bool]
        /// Есть план сборки, конспект устарел, материалы устарели — когда фоновый пересчёт готов.
        var summary: [Bool]?
    }

    private var primaryKey: PrimaryKey {
        PrimaryKey(meta: lecture.meta, busy: [recognition.isBusy(lecture.id), assembly.isRunning(lecture.id),
                                              study.isRunning(lecture.id),
                                              study.errors[lecture.id] != nil],
                   summary: assembly.knownReadiness(lecture).map { [$0.plan != nil, $0.isStale, study.knownStale(lecture)] })
    }

    var body: some View {
        VStack(spacing: 0) {
            notices
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
                    if tab.isStudy { studyModePicker }
                }
        }
        .onChange(of: primaryKey, initial: true) {
            primary = LecturePrimaryAction.next(for: lecture, recognition: recognition, assembly: assembly, study: study)
        }
        .motion(.standard, value: lecture.hasConflict)
        .motion(.standard, value: lecture.meta.dateAdjustment)
        .navigationTitle(lecture.meta.topic)
        .navigationSubtitle("\(lecture.meta.subject) · \(lecture.meta.date.formatted)")
        .toolbar { toolbar }
        .environment(\.lectureRequests, $requests)
        .environment(\.notesFlush, notesFlush)
        .focusedSceneValue(\.lectureCommands, commands)
        .sheet(isPresented: Binding(get: { export?.askAnki ?? false }, set: { export?.askAnki = $0 })) {
            if let export { AnkiExportSheet(export: export) }
        }
        .onAppear {
            library.requestedTab = nil
            let controller = ExportController(library: library, lecture: lecture)
            controller.flushEdits = { [notesFlush] in notesFlush() }
            export = controller
        }
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

    /// Полоса самопроверки (режим, источник материалов, «Подготовить заново»). Одна на все три вкладки и лежит
    /// поверх них: будь она в каждой вкладке, при щелчке нажатый переключатель пропадал бы вместе со своей
    /// вкладкой, а на его месте появлялся другой — нажатие обрывалось, выбор перескакивал без анимации.
    private var studyModePicker: some View {
        StudyModeBar(lecture: lecture, mode: $tab)
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

    /// Вкладки самопроверки оставляют сверху место под общий переключатель режима (невидимая копия той же
    /// высоты): высота общей области при переходе между зонами не меняется, скрытые вкладки не раскладываются заново.
    @ViewBuilder
    private func tabContent(_ item: LectureTab) -> some View {
        if item.isStudy {
            VStack(spacing: 0) {
                StudyModeBar(lecture: lecture, mode: .constant(item))
                    .hidden()
                    .accessibilityHidden(true)
                screen(item)
            }
            .background(Color.surfaceStudy)
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
            LectureActivityIndicator(lecture: lecture, exportingPDFSince: export?.exportingPDFSince,
                                     exportingHTMLSince: export?.exportingHTMLSince)
        }
        if let primary {
            ToolbarItem {
                // Уступив роль главной кнопке «PDF», следующий шаг сжимается до значка: с двумя подписями
                // тулбар окна по умолчанию переполняется и прячет «PDF» в меню ».
                Button { perform(primary) } label: {
                    if prominentButton == .pdf {
                        Label(primary.title, systemImage: primary.systemImage).labelStyle(.iconOnly)
                    } else {
                        Label(primary.title, systemImage: primary.systemImage).labelStyle(.titleAndIcon)
                    }
                }
                .prominentAction(prominentButton == .primary)
                .help("\(primary.title) — следующий шаг (⌘↩)")
            }
        }
        if let export, export.hasKonspekt {
            ToolbarItem {
                PDFExportButton(export: export, prominent: prominentButton == .pdf, available: pdfAvailable)
            }
        }
        ToolbarItem {
            EngineModeMenu()
        }
        ToolbarItem {
            Menu {
                if let export { ExportMenuItems(export: export, available: pdfAvailable) }
                Divider()
                Button("Изменить лекцию…") { library.sheet = .editLecture(lecture.id) }
                Button("Показать в Finder") { library.revealInFinder(lecture.folder) }
                Divider()
                Button("Удалить лекцию…", role: .destructive) { library.requestDeleteLecture(lecture.id) }
            } label: {
                Label("Ещё", systemImage: "ellipsis")
            }
            .help("Экспорт, изменение и удаление лекции")
        }
    }

    /// Пока конспект пересобирается, его не экспортируют.
    private var pdfAvailable: Bool { export?.hasKonspekt == true && !assembly.isRunning(lecture.id) }

    private var prominentButton: LectureProminentButton {
        LectureProminentButton.choose(primary: primary, pdfAvailable: pdfAvailable,
                                      summaryKnown: assembly.knownReadiness(lecture) != nil, tab: tab)
    }

    private var neighbors: LectureNeighbors { library.neighbors(of: lecture.id) }

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

    private var commands: LectureCommands {
        LectureCommands(
            tab: $tab, primary: primary, perform: perform,
            reviewCards: lecture.meta.study != nil && !study.isRunning(lecture.id)
                ? { tab = .flashcards; requests.reviewCards = true } : nil,
            exportMarkdown: export?.hasKonspekt == true ? { export?.exportMarkdown() } : nil,
            exportPDF: pdfAvailable && export?.exportingPDFSince == nil ? { export?.exportPDF() } : nil,
            exportCheatSheet: pdfAvailable && export?.exportingPDFSince == nil ? { export?.exportCheatSheet() } : nil,
            exportHTML: pdfAvailable && export?.exportingHTMLSince == nil ? { export?.exportHTML() } : nil,
            exportAnki: export?.hasStudy == true ? { export?.askAnki = true } : nil,
            copyForChat: export?.hasKonspekt == true ? { export?.copyForChat() } : nil,
            previousLecture: neighbors.previous.map { link in { library.openLecture(link.id, tab: tab) } },
            nextLecture: neighbors.next.map { link in { library.openLecture(link.id, tab: tab) } },
            edit: { library.sheet = .editLecture(lecture.id) },
            reveal: { library.revealInFinder(lecture.folder) },
            addFiles: { tab = .sources; requests.addFiles = true },
            delete: { library.requestDeleteLecture(lecture.id) },
            cancelWork: recognition.isBusy(lecture.id) || assembly.isRunning(lecture.id) || study.isRunning(lecture.id)
                ? { [id = lecture.id] in
                    recognition.cancel(lectureID: id)
                    assembly.cancel(id)
                    study.cancel(id)
                } : nil)
    }
}
