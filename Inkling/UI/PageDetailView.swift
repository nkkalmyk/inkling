import SwiftUI

/// Выбранная страница: фото или слайд и распознанный текст бок о бок (SPEC, раздел 7).
struct PageDetailView: View {
    @Environment(Library.self) private var library
    let lecture: LectureRecord
    let pageID: String?

    var body: some View {
        if let pageID, let location = lecture.meta.page(pageID) {
            PageEditor(lecture: lecture, pageID: pageID, section: location.section, number: location.index + 1)
                .id(pageID)
        } else {
            ContentUnavailableView("Выберите страницу", systemImage: "doc.viewfinder",
                                   description: Text("Порядок меняется перетаскиванием, лишние страницы удаляются клавишей ⌫."))
        }
    }
}

private struct PageEditor: View {
    @Environment(Library.self) private var library
    @Environment(RecognitionCenter.self) private var recognition
    let lecture: LectureRecord
    let pageID: String
    let section: SourceSection
    let number: Int

    @State private var text = ""
    @State private var loadedRevision: Int?
    @State private var image: NSImage?
    @State private var zoom: ZoomableImageView.ZoomRequest?
    @State private var saveTask: Task<Void, Never>?
    @State private var confirmRerecognize = false
    @State private var showHistory = false

    private var paths: LecturePaths { LecturePaths(folder: lecture.folder) }
    private var note: NotePage? { lecture.meta.notes.first { $0.id == pageID } }
    private var slide: SlidePage? { lecture.meta.slides.first { $0.id == pageID } }
    private var info: PageText? { lecture.meta.pageText(pageID) }
    private var revision: Int { library.pageRevisions[pageID] ?? 0 }
    private var busy: Bool { library.busyPages.contains(pageID) }

    private var imageSource: PageImageSource? {
        if let note { return paths.imageSource(for: note) }
        if let slide { return paths.imageSource(for: slide) }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(10)
            Divider()
            HSplitView {
                ZoomableImageView(image: image, zoom: zoom)
                    .frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 0) {
                    statusLine
                    Divider()
                    textArea
                }
                .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(imageSource.map { "\($0)" } ?? "")#\(revision)") {
            guard let imageSource else { return }
            image = await PageImageLoader.shared.image(imageSource, maxPixel: 2400, revision: revision)
        }
        .onAppear(perform: loadText)
        .onChange(of: revision) { loadText() }
        .onDisappear(perform: flushSave)
        .confirmationDialog("Текст правился вручную", isPresented: $confirmRerecognize) {
            Button("Распознать заново") { recognition.recognize(lectureID: lecture.id, pageIDs: [pageID]) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Ваша версия сохранится в истории, её можно будет восстановить.")
        }
    }

    // MARK: Шапка

    private var header: some View {
        HStack(spacing: 8) {
            Text(section == .notes ? "Страница \(number)" : "Слайд \(number)").font(.headline)
            Spacer()
            if let note { noteControls(note) }
            if let slide { slideControls(slide) }
            Divider().frame(height: 18)
            Button("Распознать заново") {
                flushSave()
                if info?.manuallyEdited == true { confirmRerecognize = true }
                else { recognition.recognize(lectureID: lecture.id, pageIDs: [pageID]) }
            }
            .disabled(isRunning || (slide.map { !$0.usesImage } ?? false))
            .help(slide.map { !$0.usesImage } ?? false ? "Слайд берётся из текстового слоя; переключите режим на «Картинка»" : "")
            Button {
                flushSave()
                showHistory = true
            } label: {
                Label("История", systemImage: "clock.arrow.circlepath")
            }
            .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                PageHistoryPopover(lecture: lecture, pageID: pageID, section: section)
            }
        }
        .disabled(busy)
    }

    @ViewBuilder
    private func noteControls(_ page: NotePage) -> some View {
        ControlGroup {
            Button { library.rotateNote(page.id, by: -1, lectureID: lecture.id) } label: {
                Label("Повернуть влево", systemImage: "rotate.left")
            }
            Button { library.rotateNote(page.id, by: 1, lectureID: lecture.id) } label: {
                Label("Повернуть вправо", systemImage: "rotate.right")
            }
        }
        .fixedSize()
        if case .original = page.crop {
            Button("Автообрезка") { library.setCrop(.auto(nil), forNote: page.id, lectureID: lecture.id) }
        } else {
            Button("Оригинал") { library.setCrop(.original, forNote: page.id, lectureID: lecture.id) }
                .help("Использовать фото без обрезки")
        }
    }

    @ViewBuilder
    private func slideControls(_ page: SlidePage) -> some View {
        if page.source.isPDF {
            Picker("Режим", selection: Binding(
                get: { page.mode },
                set: { library.setSlideMode($0, for: page.id, lectureID: lecture.id) })) {
                Text(page.heuristicNeedsImage ? "Авто: картинка" : "Авто: текст").tag(SlideMode.auto)
                Text("Текстовый слой").tag(SlideMode.textLayer)
                Text("Картинка").tag(SlideMode.image)
            }
            .labelsHidden()
            .fixedSize()
            .help(page.heuristicReason.map { "Эвристика выбрала картинку: \($0)" } ?? "Текстовый слой выглядит нормально")
        }
        Toggle("Не в конспект", isOn: Binding(
            get: { page.excluded },
            set: { library.setSlideExcluded($0, for: page.id, lectureID: lecture.id) }))
            .help("Не включать слайд в конспект (титульник, «Спасибо за внимание»)")
    }

    // MARK: Статус и текст

    private var isRunning: Bool {
        switch recognition.state(of: pageID) {
        case .queued, .running: true
        default: false
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 6) {
            switch recognition.state(of: pageID) {
            case .queued:
                Image(systemName: "clock").foregroundStyle(.secondary)
                Text("В очереди на распознавание")
            case .running(let engine, let startedAt):
                ProgressView().controlSize(.small)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Распознаёт \(engine.title) · \(Int(context.date.timeIntervalSince(startedAt))) с")
                }
            case .failed(let error):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(error.userMessage).lineLimit(2)
                    .help(error.details)
            case nil:
                provenance
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var provenance: some View {
        if let info {
            switch info.origin {
            case .model:
                Text("\(info.engine?.title ?? "Модель") · \(info.model ?? "") · \(info.updatedAt.formatted(Self.dateFormat))")
            case .textLayer:
                Text("Текстовый слой PDF")
            case .manual:
                Text("Набрано вручную")
            }
            if info.origin == .model {
                ReviewBadge(engine: info.engine, manuallyEdited: info.manuallyEdited)
            }
            if info.manuallyEdited && info.origin != .manual {
                Label("правлено вручную", systemImage: "pencil").labelStyle(.titleAndIcon)
            }
            if note?.textIsStale == true {
                Label("фото изменено после распознавания", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            }
        } else {
            Text("Не распознано")
        }
    }

    private static let dateFormat = Date.FormatStyle().day().month(.abbreviated).hour().minute()
        .locale(Locale(identifier: "ru_RU"))

    @ViewBuilder
    private var textArea: some View {
        if info == nil && text.isEmpty && !isRunning {
            VStack(spacing: 10) {
                Text("Текста пока нет.").foregroundStyle(.secondary)
                if slide.map(\.usesImage) ?? true {
                    Button("Распознать") { recognition.recognize(lectureID: lecture.id, pageIDs: [pageID]) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PageTextEditor(text: Binding(get: { text }, set: { newValue in
                text = newValue
                scheduleSave()
            }), onIllegibleClick: { zoom = .init(relativeY: $0) })
        }
    }

    // MARK: Загрузка и сохранение

    private func loadText() {
        guard loadedRevision != revision || text.isEmpty else { return }
        loadedRevision = revision
        text = PageTextStore(paths: paths).read(pageID, in: section) ?? ""
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            library.saveEditedText(text, pageID: pageID, lectureID: lecture.id)
        }
    }

    private func flushSave() {
        guard let task = saveTask else { return }
        task.cancel()
        saveTask = nil
        library.saveEditedText(text, pageID: pageID, lectureID: lecture.id)
    }
}

// MARK: История

private struct PageHistoryPopover: View {
    @Environment(Library.self) private var library
    let lecture: LectureRecord
    let pageID: String
    let section: SourceSection
    @State private var selected: HistoryStore.Entry?
    @State private var preview = ""

    private var entries: [HistoryStore.Entry] {
        PageTextStore(paths: LecturePaths(folder: lecture.folder)).history(pageID, in: section).entries()
    }

    var body: some View {
        let entries = entries
        VStack(alignment: .leading, spacing: 8) {
            Text("История версий").font(.headline)
            if entries.isEmpty {
                Text("Предыдущих версий нет. Они появляются, когда текст перезаписывается.")
                    .foregroundStyle(.secondary)
                    .frame(width: 320)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    List(entries, selection: Binding(get: { selected?.id }, set: { id in
                        selected = entries.first { $0.id == id }
                        preview = selected.flatMap { try? String(contentsOf: $0.file, encoding: .utf8) } ?? ""
                    })) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.date.formatted(.dateTime.day().month().hour().minute().second()
                                .locale(Locale(identifier: "ru_RU"))))
                            Text(describe(entry.info(PageText.self))).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(entry.id)
                    }
                    .frame(width: 220, height: 260)
                    ScrollView {
                        Text(preview.isEmpty ? "Выберите версию слева" : preview)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(preview.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: 320, height: 260)
                }
                HStack {
                    Spacer()
                    Button("Восстановить эту версию") {
                        if let selected { library.restoreVersion(selected, pageID: pageID, lectureID: lecture.id) }
                    }
                    .disabled(selected == nil)
                }
            }
        }
        .padding(14)
    }

    private func describe(_ info: PageText?) -> String {
        guard let info else { return "без описания" }
        var parts: [String]
        switch info.origin {
        case .model: parts = [info.model ?? info.engine?.title ?? "модель"]
        case .textLayer: parts = ["текстовый слой"]
        case .manual: parts = ["набрано вручную"]
        }
        if info.manuallyEdited && info.origin != .manual { parts.append("правлено вручную") }
        return parts.joined(separator: " · ")
    }
}
