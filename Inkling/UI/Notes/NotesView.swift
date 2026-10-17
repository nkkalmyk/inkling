import SwiftUI

/// Вкладка «Конспект» (SPEC, разделы 4 и 7): сборка, просмотр с формулами, правка, история, «Устарело».
struct NotesView: View {
    @Environment(Library.self) private var library
    @Environment(AssemblyCenter.self) private var assembly
    @Environment(EnrichmentCenter.self) private var enrichment
    @Environment(RecognitionCenter.self) private var recognition
    let lecture: LectureRecord

    @State private var editing = false
    @State private var text = ""
    @State private var loadedRevision: Int?
    @State private var saveTask: Task<Void, Never>?
    @State private var confirm: Confirmation?
    @State private var showHistory = false
    @State private var katexErrors = 0
    @Environment(\.lectureRequests) private var requests
    @Environment(\.isActiveTab) private var isActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Confirmation: Identifiable {
        case overwriteManual, skipUnrecognized(Int)
        var id: String { if case .overwriteManual = self { "manual" } else { "skip" } }
    }

    private var store: KonspektStore { KonspektStore(folder: lecture.folder) }
    private var revision: Int { library.konspektRevision[lecture.id] ?? 0 }
    private var info: ArtifactInfo? { lecture.meta.konspekt }

    var body: some View {
        // Из кэша: тексты страниц читаются в фоне, `nil` — ещё читаются.
        let readiness = assembly.knownReadiness(lecture)
        VStack(spacing: 0) {
            if let error = enrichment.errors[lecture.id], !enrichment.isRunning(lecture.id) {
                InlineNotice(.error, "Конспект не дополнен. \(error.userMessage)", systemImage: "exclamationmark.octagon.fill",
                             details: error.details, dismiss: { enrichment.errors[lecture.id] = nil }) {
                    Button("Повторить") { enrich() }
                }
                .transition(.notice(reduceMotion: reduceMotion))
                Divider()
            }
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
                                 systemImage: "clock.arrow.circlepath") {
                        Button("Пересобрать") { start(force: false) }
                            .disabled(recognition.isBusy(lecture.id))
                    }
                    .transition(.notice(reduceMotion: reduceMotion))
                    Divider()
                }
            }
            if info == nil && text.isEmpty {
                emptyState(readiness)
            } else {
                header(readiness)
                Divider()
                if editing {
                    PageTextEditor(text: Binding(get: { text }, set: { text = $0; scheduleSave() }))
                } else {
                    NotesWebView(markdown: text) { katexErrors = $0 }
                }
            }
        }
        .motion(.standard, value: assembly.errors[lecture.id] == nil)
        .motion(.standard, value: enrichment.errors[lecture.id] == nil)
        .motion(.standard, value: readiness?.isStale == true)
        .focusedSceneValue(\.notesEditing, !isActive || info == nil && text.isEmpty ? nil : $editing)
        .onChange(of: isActive) { if !isActive { flushSave() } }
        .task(id: requests.wrappedValue.assemble && isActive) {
            guard requests.wrappedValue.assemble, isActive else { return }
            requests.wrappedValue.assemble = false
            start(force: false)
        }
        .task(id: requests.wrappedValue.enrich && isActive) {
            guard requests.wrappedValue.enrich, isActive else { return }
            requests.wrappedValue.enrich = false
            enrich()
        }
        .task(id: LoadKey(revision: revision, konspekt: lecture.meta.konspekt)) { await load() }
        .onDisappear(perform: flushSave)
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            presenting: confirm) { _ in
            Button("Собрать") { start(force: true) }
            Button("Отмена", role: .cancel) {}
        } message: { which in
            switch which {
            case .overwriteManual: Text("Конспект правился вручную. Ваша версия сохранится в истории.")
            case .skipUnrecognized(let n): Text("Не распознано страниц: \(n). Они не попадут в конспект.")
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
            }
            Spacer()
            // При «Устарело» кнопка «Пересобрать» есть в уведомлении над шапкой — здесь не повторяем.
            if readiness?.isStale != true || assembly.errors[lecture.id] != nil {
                Button(info == nil ? "Собрать" : "Пересобрать") { start(force: false) }
                    .disabled(assembly.isRunning(lecture.id) || readiness?.plan == nil || recognition.isBusy(lecture.id))
            }
            if info != nil {
                Button("Дополнить") { enrich() }
                    .disabled(assembly.isRunning(lecture.id) || enrichment.isRunning(lecture.id)
                              || recognition.isBusy(lecture.id))
                    .help((info?.enrichment == nil ? "" : "Прежнее дополнение заменится. ")
                          + "Добавить резюме, пояснения, примеры и схемы помеченными блоками. Текст автора не меняется, "
                          + "добавленное проверяется вторым проходом. Только через Claude.")
            }
            Button {
                flushSave()
                showHistory = true
            } label: {
                Label("История", systemImage: "clock.arrow.circlepath")
            }
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

    private func start(force: Bool) {
        flushSave()
        if !force {
            let missing = assembly.readiness(lecture).input
            let skipped = missing.unrecognizedNotes + missing.unrecognizedSlides
            if info?.manuallyEdited == true { confirm = .overwriteManual; return }
            if skipped > 0 { confirm = .skipUnrecognized(skipped); return }
        }
        editing = false
        assembly.assemble(lecture.id)
    }

    private func enrich() {
        flushSave()
        enrichment.enrich(lecture.id)
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
        let loaded = await Self.read(store)
        guard !Task.isCancelled, loadedRevision != target || text.isEmpty || !editing else { return }
        loadedRevision = target
        text = loaded
    }

    @concurrent
    private static func read(_ store: KonspektStore) async -> String {
        store.read()?.trimmingCharacters(in: .newlines) ?? ""
    }

    private func scheduleSave() {
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
