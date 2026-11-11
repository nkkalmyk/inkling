import SwiftUI

/// Вкладка «Конспект» (SPEC, разделы 4 и 7): сборка, просмотр с формулами, правка, история, «Устарело».
struct NotesView: View {
    @Environment(Library.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(AssemblyCenter.self) private var assembly
    @Environment(KonspektCheckCenter.self) private var checker
    @Environment(RecognitionCenter.self) private var recognition
    let lecture: LectureRecord
    /// Переход на «Источники» из пустого состояния, когда собирать ещё не из чего.
    var showSources: () -> Void = {}

    @State private var editing = false
    /// `konspekt.md` есть по описанию, но не прочитался (выгружен в iCloud без сети, нет доступа): правка отключена,
    /// иначе набранный в пустом поле текст записался бы поверх настоящего конспекта.
    @State private var readFailed = false
    @State private var text = ""
    @State private var loadedRevision: Int?
    @State private var saveTask: Task<Void, Never>?
    @State private var editsID = UUID()
    @State private var confirm: Confirmation?
    @State private var showHistory = false
    @State private var katexErrors = 0
    @Environment(\.lectureRequests) private var requests
    @Environment(\.notesFlush) private var notesFlush
    @Environment(KonspektSearchCenter.self) private var search
    /// Для какой лекции загружен `text`: при смене лекции вид может на миг показать прежний текст.
    @State private var loadedFor: UUID?
    @Environment(\.isActiveTab) private var isActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Confirmation: Identifiable {
        /// `skipped` — сколько нераспознанных страниц не попадёт в конспект: второго вопроса после этого не будет.
        case overwriteManual(skipped: Int), skipUnrecognized(Int)
        var id: String { if case .overwriteManual = self { "manual" } else { "skip" } }
    }

    private var store: KonspektStore { KonspektStore(folder: lecture.folder) }
    private var revision: Int { library.konspektRevision[lecture.id] ?? 0 }
    private var info: ArtifactInfo? { lecture.meta.konspekt }

    /// Раздел, к которому прокрутить: пришли сюда по ссылке на понятие из другой лекции. Только когда показан
    /// уже текст этой лекции.
    private var anchor: String? {
        guard loadedFor == lecture.id, let request = library.requestedAnchor, request.lecture == lecture.id else { return nil }
        return request.anchor
    }

    var body: some View {
        // Из кэша: тексты страниц читаются в фоне, `nil` — ещё читаются.
        let readiness = assembly.knownReadiness(lecture)
        VStack(spacing: 0) {
            if !assembly.isRunning(lecture.id) {
                if let error = assembly.errors[lecture.id] {
                    InlineNotice(.error, "Конспект не собран. \(error.userMessage)", systemImage: "exclamationmark.octagon.fill",
                                 details: error.details, dismiss: { assembly.errors[lecture.id] = nil }) {
                        Button("Повторить") { start(force: true) }
                    }
                    .transition(.notice(reduceMotion: reduceMotion))
                    Divider()
                } else if readiness?.isStale == true {
                    InlineNotice(.info, "Устарело: тексты или порядок страниц изменились после сборки.",
                                 systemImage: "exclamationmark.arrow.circlepath") {
                        Button("Пересобрать") { start(force: false) }
                            .disabled(recognition.isBusy(lecture.id))
                    }
                    .transition(.notice(reduceMotion: reduceMotion))
                    Divider()
                }
            }
            if readFailed {
                InlineNotice(.error, "Не удалось прочитать файл конспекта. Правка отключена, чтобы не затереть его; "
                             + "если файл загружается из iCloud, подождите.", systemImage: "exclamationmark.triangle.fill")
                Divider()
            }
            if info == nil && text.isEmpty {
                emptyState(readiness)
            } else {
                header(readiness)
                Divider()
                // Просмотр и правка сменяют друг друга растворением, а не скачком.
                ZStack {
                    if editing {
                        PageTextEditor(text: Binding(get: { text }, set: { text = $0; scheduleSave() }),
                                       isEditable: !readFailed && !assembly.isRunning(lecture.id))
                            .transition(.opacity)
                    } else {
                        NotesWebView(markdown: text, neighbors: library.neighbors(of: lecture.id),
                                     concepts: search.conceptLinks(for: lecture.id,
                                                                   among: library.subjectLectures(containing: lecture.id)),
                                     anchor: anchor,
                                     onScrolled: { library.requestedAnchor = nil },
                                     openLecture: { library.openLecture($0, tab: .notes, anchor: $1) }) { katexErrors = $0 }
                            .transition(.opacity)
                    }
                }
                .motion(.standard, value: editing)
            }
        }
        .motion(.standard, value: assembly.errors[lecture.id] == nil)
        .motion(.standard, value: readiness?.isStale == true)
        .focusedSceneValue(\.notesEditing, !isActive || info == nil && text.isEmpty ? nil : $editing)
        .onChange(of: isActive) { if !isActive { flushSave() } }
        .task(id: requests.wrappedValue.assemble && isActive) {
            guard requests.wrappedValue.assemble, isActive else { return }
            requests.wrappedValue.assemble = false
            start(force: false)
        }
        .task(id: LoadKey(revision: revision, konspekt: lecture.meta.konspekt)) { await load() }
        .task(id: LoadKey(revision: revision, konspekt: lecture.meta.konspekt)) { checker.refresh(lecture) }
        .onAppear {
            notesFlush?.action = flushSave
            PendingEdits.register(editsID, flush: flushSave)
        }
        .onDisappear {
            flushSave()
            PendingEdits.unregister(editsID)
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            presenting: confirm) { which in
            Button(which.id == "manual" ? "Пересобрать" : "Собрать") { start(force: true) }
            Button("Отмена", role: .cancel) {}
        } message: { which in
            switch which {
            case .overwriteManual(let skipped):
                Text("Конспект правился вручную. Ваша версия сохранится в истории."
                     + (skipped > 0 ? " Не распознано: \(UIFormat.count(skipped, "страница", "страницы", "страниц")) — они не попадут в конспект." : ""))
            case .skipUnrecognized(let n):
                Text("Не распознано: \(UIFormat.count(n, "страница", "страницы", "страниц")). Они не попадут в конспект.")
            }
        }
    }

    // MARK: Состояния

    private func emptyState(_ readiness: AssemblyCenter.Readiness?) -> some View {
        EmptyState("Конспекта пока нет", systemImage: "doc.richtext",
                   description: readiness.map { readiness in
                       readiness.plan.map { planDescription($0, readiness.input) }
                           ?? "Сначала добавьте и распознайте страницы на вкладке «Источники»."
                   }) {
            if readiness?.plan != nil, !assembly.isRunning(lecture.id) {
                Button("Собрать конспект") { start(force: false) }
                    .prominentAction()
                    .disabled(recognition.isBusy(lecture.id))
            } else if readiness != nil, readiness?.plan == nil {
                Button("Перейти к источникам", action: showSources)
            }
            if recognition.isBusy(lecture.id) {
                Text("Дождитесь окончания распознавания.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func header(_ readiness: AssemblyCenter.Readiness?) -> some View {
        HStack(spacing: Spacing.m) {
            Picker("Режим", selection: $editing) {
                Text("Просмотр").tag(false)
                Text("Правка").tag(true)
            }
            .sectionSwitcher(.inline)
            .onChange(of: editing) { if !editing { flushSave() } }

            provenance
            if katexErrors > 0 && !editing {
                Label("ошибок в формулах: \(katexErrors)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.statusError)
                    .help("Формулы с ошибкой показаны исходным LaTeX красным")
                if checker.checks[lecture.id]?.brokenFormulas.isEmpty == false {
                    if checker.isFixing(lecture.id) {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Исправление формул")
                            .help("Идёт исправление формул; отменить можно в индикаторе работы на панели")
                    } else {
                        Button("Исправить формулы") { flushSave(); checker.fixFormulas(lecture.id) }
                            .help("Один короткий вызов модели: исправляется только синтаксис формул, смысл не меняется. Прежняя версия уйдёт в историю.")
                    }
                }
            }
            if let check = checker.checks[lecture.id], !check.missingStructure.isEmpty || check.diagramErrors > 0, !editing {
                Label("проверка: " + KonspektCheck(diagramErrors: check.diagramErrors, missingStructure: check.missingStructure).summary,
                      systemImage: "checklist")
                    .foregroundStyle(.secondary)
                    .help("Локальная проверка конспекта. Недостающие разделы появятся после «Пересобрать».")
            }
            Spacer()
            // При «Устарело» кнопка «Пересобрать» есть в уведомлении над шапкой — здесь не повторяем.
            if readiness?.isStale != true || assembly.errors[lecture.id] != nil {
                assembleMenu(title: info == nil ? "Собрать" : "Пересобрать", disabled: assembly.isRunning(lecture.id)
                             || readiness?.plan == nil || recognition.isBusy(lecture.id))
            }
            Button {
                flushSave()
                showHistory = true
            } label: {
                Label("История", systemImage: "clock.arrow.circlepath")
                    .labelStyle(.iconOnly)
            }
            .help("История версий конспекта")
            .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                HistoryPopover(entries: store.history.entries(),
                               emptyHint: "Они появляются, когда конспект перезаписывается.",
                               subtitle: { describe($0.info(ArtifactInfo.self)) },
                               restore: { library.restoreKonspekt($0, lectureID: lecture.id) })
            }
        }
        .font(.meta)
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
    }

    @ViewBuilder
    private var provenance: some View {
        if let info {
            Text(describe(info)).foregroundStyle(.secondary).lineLimit(1)
                .help(provenanceHelp(info))
            ReviewBadge(engine: info.engine, manuallyEdited: info.manuallyEdited)
        }
    }

    private func describe(_ info: ArtifactInfo?) -> String {
        guard let info else { return "без описания" }
        var parts: [String] = []
        if let model = info.model { parts.append(model) }
        if info.style == .study { parts.append("учебный") }
        if let mode = info.mode { parts.append(mode.title) }
        if info.parts > 1 { parts.append("частей: \(info.parts)") }
        parts.append(info.updatedAt.stamp)
        if info.enrichment != nil { parts.append("дополнен") }
        if info.manuallyEdited { parts.append("правлено вручную") }
        return parts.joined(separator: " · ")
    }

    private func provenanceHelp(_ info: ArtifactInfo) -> String {
        var lines: [String] = []
        if info.skippedPages > 0 { lines.append("При сборке пропущено нераспознанных страниц: \(info.skippedPages)") }
        if let added = info.enrichment {
            var line = "Дополнено \(added.createdAt.stamp): блоков \(added.added)"
            if added.removedByCheck > 0 { line += ", убрано проверкой \(added.removedByCheck)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private func planDescription(_ plan: AssemblyPlan, _ input: AssemblyInput) -> String {
        var lines = ["Сборка \(plan.mode.title): страниц \(input.notes.count), слайдов \(input.slides.count)."]
        if plan.needsMerge { lines.append("Лекция длинная: соберу по частям (\(plan.parts.count)) и склею.") }
        let missing = input.unrecognizedNotes + input.unrecognizedSlides
        if missing > 0 { lines.append("Не распознано: \(missing) — они не попадут в конспект.") }
        return lines.joined(separator: "\n")
    }

    private var confirmTitle: String {
        switch confirm {
        case .overwriteManual: "Пересобрать конспект?"
        case .skipUnrecognized: "Собрать без нераспознанных страниц?"
        case nil: ""
        }
    }

    // MARK: Действия

    /// Кнопка сборки: по щелчку — стиль из настроек, в меню — другой стиль и модель Claude.
    private func assembleMenu(title: String, disabled: Bool) -> some View {
        @Bindable var settings = settings
        return Menu(title) {
            ForEach(AssemblyStyle.allCases) { style in
                Button(style.title) { start(force: false, style: style) }
                    .help(style.hint)
            }
            Divider()
            // Это общая настройка сборки, а не выбор на один запуск: подпись говорит об этом прямо.
            Picker("Модель Claude (для всех сборок)", selection: $settings.assemblyModel) {
                Text("Как в настройках").tag("")
                ForEach(AppSettings.claudeModels, id: \.id) { Text($0.title).tag($0.id) }
            }
        } primaryAction: {
            start(force: false)
        }
        .fixedSize()
        .disabled(disabled)
        .help(recognition.isBusy(lecture.id) ? "Дождитесь окончания распознавания"
              : assembly.isRunning(lecture.id) ? "Конспект уже собирается"
              : "\(settings.assemblyStyle.title). Стрелка — выбрать стиль и модель.")
    }

    private func start(force: Bool, style: AssemblyStyle? = nil) {
        flushSave()
        if !force {
            // Из кэша, без чтения файлов на главном потоке; пока сводки нет — читаем сейчас (редкий случай).
            let missing = (assembly.knownReadiness(lecture) ?? assembly.readiness(lecture)).input
            let skipped = missing.unrecognizedNotes + missing.unrecognizedSlides
            if info?.manuallyEdited == true { confirm = .overwriteManual(skipped: skipped); return }
            if skipped > 0 { confirm = .skipUnrecognized(skipped); return }
        }
        editing = false
        assembly.assemble(lecture.id, style: style)
    }

    /// Когда перечитывать конспект: новая ревизия (сборка, восстановление) или новые сведения о нём.
    private struct LoadKey: Equatable {
        var revision: Int
        var konspekt: ArtifactInfo?
    }

    /// Читает конспект в фоне: файл может быть выгружен в iCloud, и чтение на главном потоке ждало бы загрузки.
    /// Во время правки не перезаписывает набранный текст, кроме случая новой ревизии.
    private func load() async {
        guard loadedRevision != revision || text.isEmpty || !editing else { return }
        let target = revision
        var loaded = await Self.read(store)
        // Файл мог ещё качаться из iCloud: пробуем снова, пока вкладка открыта (задача отменяется при уходе).
        var attempts = 0
        while loaded == nil, lecture.meta.konspekt != nil, attempts < 40, !Task.isCancelled {
            readFailed = true
            attempts += 1
            try? await Task.sleep(for: .seconds(3))
            loaded = await Self.read(store)
        }
        guard !Task.isCancelled, loadedRevision != target || text.isEmpty || !editing else { return }
        readFailed = loaded == nil && lecture.meta.konspekt != nil
        guard !readFailed else { return }
        loadedRevision = target
        text = loaded ?? ""
        loadedFor = lecture.id
    }

    @concurrent
    private static func read(_ store: KonspektStore) async -> String? {
        store.read()?.trimmingCharacters(in: .newlines)
    }

    private func scheduleSave() {
        guard !readFailed else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            library.saveKonspektEdit(text + "\n", lectureID: lecture.id)
        }
    }

    private func flushSave() {
        guard let task = saveTask else { return }
        task.cancel()
        saveTask = nil
        library.saveKonspektEdit(text + "\n", lectureID: lecture.id)
    }
}
