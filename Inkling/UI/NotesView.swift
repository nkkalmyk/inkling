import SwiftUI

/// Вкладка «Конспект» (SPEC, разделы 4 и 7): сборка, просмотр с формулами, правка, история, «Устарело».
struct NotesView: View {
    @Environment(Library.self) private var library
    @Environment(AssemblyCenter.self) private var assembly
    @Environment(RecognitionCenter.self) private var recognition
    let lecture: LectureRecord

    @State private var editing = false
    @State private var text = ""
    @State private var loadedRevision: Int?
    @State private var saveTask: Task<Void, Never>?
    @State private var confirm: Confirmation?
    @State private var showHistory = false
    @State private var katexErrors = 0
    @State private var showErrorDetails = false

    private enum Confirmation: Identifiable {
        case overwriteManual, skipUnrecognized(Int)
        var id: String { if case .overwriteManual = self { "manual" } else { "skip" } }
    }

    private var store: KonspektStore { KonspektStore(folder: lecture.folder) }
    private var revision: Int { library.konspektRevision[lecture.id] ?? 0 }
    private var info: ArtifactInfo? { lecture.meta.konspekt }

    var body: some View {
        let readiness = assembly.readiness(lecture)
        VStack(spacing: 0) {
            if let run = assembly.runs[lecture.id] {
                runningBar(run)
            } else if let error = assembly.errors[lecture.id] {
                errorBar(error)
            } else if readiness.isStale {
                staleBar
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
        .onAppear(perform: load)
        .onChange(of: revision) { load() }
        .onChange(of: lecture.meta.konspekt) { if !editing { load() } }
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

    private func emptyState(_ readiness: AssemblyCenter.Readiness) -> some View {
        ContentUnavailableView {
            Label("Конспекта пока нет", systemImage: "doc.richtext")
        } description: {
            if let plan = readiness.plan {
                Text(planDescription(plan, readiness.input))
            } else {
                Text("Сначала добавьте и распознайте страницы на вкладке «Источники».")
            }
        } actions: {
            if readiness.plan != nil, !assembly.isRunning(lecture.id) {
                Button("Собрать конспект") { start(force: false) }
                    .buttonStyle(.borderedProminent)
                    .disabled(recognition.isBusy(lecture.id))
            }
            if recognition.isBusy(lecture.id) {
                Text("Дождитесь окончания распознавания.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func header(_ readiness: AssemblyCenter.Readiness) -> some View {
        HStack(spacing: 10) {
            Picker("Режим", selection: $editing) {
                Text("Просмотр").tag(false)
                Text("Правка").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .onChange(of: editing) { if !editing { flushSave() } }

            provenance
            if katexErrors > 0 && !editing {
                Label("ошибок в формулах: \(katexErrors)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .help("Формулы с ошибкой показаны исходным LaTeX красным")
            }
            Spacer()
            Button(info == nil ? "Собрать" : "Пересобрать") { start(force: false) }
                .disabled(assembly.isRunning(lecture.id) || readiness.plan == nil || recognition.isBusy(lecture.id))
            Button {
                flushSave()
                showHistory = true
            } label: {
                Label("История", systemImage: "clock.arrow.circlepath")
            }
            .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                ArtifactHistoryPopover(history: store.history, describe: describe) { entry in
                    library.restoreKonspekt(entry, lectureID: lecture.id)
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var provenance: some View {
        if let info {
            Text(describe(info)).foregroundStyle(.secondary).lineLimit(1)
                .help(info.skippedPages > 0 ? "При сборке пропущено нераспознанных страниц: \(info.skippedPages)" : "")
        }
    }

    private func describe(_ info: ArtifactInfo?) -> String {
        guard let info else { return "без описания" }
        var parts: [String] = []
        if let model = info.model { parts.append(model) }
        if let mode = info.mode { parts.append(mode.title) }
        if info.parts > 1 { parts.append("частей: \(info.parts)") }
        parts.append(info.updatedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute()
            .locale(Locale(identifier: "ru_RU"))))
        if info.manuallyEdited { parts.append("правлено вручную") }
        return parts.joined(separator: " · ")
    }

    private func planDescription(_ plan: AssemblyPlan, _ input: AssemblyInput) -> String {
        var lines = ["Сборка \(plan.mode.title): страниц \(input.notes.count), слайдов \(input.slides.count)."]
        if plan.needsMerge { lines.append("Лекция длинная: соберу по частям (\(plan.parts.count)) и склею.") }
        let missing = input.unrecognizedNotes + input.unrecognizedSlides
        if missing > 0 { lines.append("Не распознано: \(missing) — они не попадут в конспект.") }
        return lines.joined(separator: "\n")
    }

    private func runningBar(_ run: AssemblyCenter.Run) -> some View {
        HStack(spacing: 10) {
            ProgressView(value: Double(run.finishedCalls), total: Double(max(run.totalCalls, 1))).frame(width: 140)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = Int(context.date.timeIntervalSince(run.startedAt))
                Text((run.merging ? "Склейка частей" : run.totalCalls > 1
                      ? "Сборка: готово частей \(run.finishedCalls) из \(run.totalCalls - 1)" : "Сборка конспекта")
                     + (run.engine.map { " · \($0.title)" } ?? "")
                     + " · \(elapsed / 60):\(String(format: "%02d", elapsed % 60))")
            }
            if let note = run.note { Text(note).foregroundStyle(.orange).lineLimit(1) }
            Spacer()
            Button("Отменить") { assembly.cancel(lecture.id) }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func errorBar(_ error: AIError) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
                Text("Конспект не собран. \(error.userMessage)")
                Spacer()
                Button("Повторить") { start(force: true) }
                Button { assembly.errors[lecture.id] = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
            if !error.details.isEmpty {
                DisclosureGroup("Подробности", isExpanded: $showErrorDetails) {
                    Text(error.details).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.red.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var staleBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange)
            Text("Устарело: тексты или порядок страниц изменились после сборки.")
            Spacer()
            Button("Пересобрать") { start(force: false) }
                .disabled(recognition.isBusy(lecture.id))
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.orange.opacity(0.1))
        .overlay(alignment: .bottom) { Divider() }
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

    private func load() {
        guard loadedRevision != revision || text.isEmpty || !editing else { return }
        loadedRevision = revision
        text = store.read()?.trimmingCharacters(in: .newlines) ?? ""
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

/// Список версий из истории с предпросмотром и восстановлением.
struct ArtifactHistoryPopover: View {
    let history: HistoryStore
    let describe: (ArtifactInfo?) -> String
    let restore: (HistoryStore.Entry) -> Void
    @State private var selected: HistoryStore.Entry?
    @State private var preview = ""

    var body: some View {
        let entries = history.entries()
        VStack(alignment: .leading, spacing: 8) {
            Text("История версий").font(.headline)
            if entries.isEmpty {
                Text("Предыдущих версий нет. Они появляются, когда конспект перезаписывается.")
                    .foregroundStyle(.secondary).frame(width: 320)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    List(entries, selection: Binding(get: { selected?.id }, set: { id in
                        selected = entries.first { $0.id == id }
                        preview = selected.flatMap { try? String(contentsOf: $0.file, encoding: .utf8) } ?? ""
                    })) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.date.formatted(.dateTime.day().month().hour().minute().second()
                                .locale(Locale(identifier: "ru_RU"))))
                            Text(describe(entry.info(ArtifactInfo.self))).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(entry.id)
                    }
                    .frame(width: 240, height: 300)
                    ScrollView {
                        Text(preview.isEmpty ? "Выберите версию слева" : preview)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(preview.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: 380, height: 300)
                }
                HStack {
                    Spacer()
                    Button("Восстановить эту версию") { if let selected { restore(selected) } }
                        .disabled(selected == nil)
                }
            }
        }
        .padding(14)
    }
}
