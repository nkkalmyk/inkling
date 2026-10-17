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
            EmptyState("Выберите страницу", systemImage: "doc.viewfinder",
                       description: "Порядок меняется перетаскиванием в ленте, лишние страницы удаляются клавишей ⌫.")
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
    @State private var rerecognizeDetailed = false
    @State private var showHistory = false
    /// Ширина панели: в узкой фото и текст встают друг под другом.
    @State private var width: CGFloat = 0

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
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, Spacing.s)
            Divider()
            if width >= 640 {
                HSplitView {
                    imagePane.frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                    textPane.frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VSplitView {
                    imagePane.frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
                    textPane.frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
        .task(id: "\(imageSource.map { "\($0)" } ?? "")#\(revision)") {
            guard let imageSource else { return }
            image = await PageImageLoader.shared.image(imageSource, maxPixel: 2400, revision: revision)
        }
        .task(id: revision) { await loadText() }
        .onDisappear(perform: flushSave)
        .confirmationDialog("Текст правился вручную", isPresented: $confirmRerecognize) {
            Button("Распознать заново") {
                recognition.recognize(lectureID: lecture.id, pageIDs: [pageID], detailed: rerecognizeDetailed)
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Ваша версия сохранится в истории, её можно будет восстановить.")
        }
    }

    private func rerecognize(detailed: Bool) {
        flushSave()
        rerecognizeDetailed = detailed
        if info?.manuallyEdited == true { confirmRerecognize = true }
        else { recognition.recognize(lectureID: lecture.id, pageIDs: [pageID], detailed: detailed) }
    }

    private var imagePane: some View {
        ZoomableImageView(image: image, zoom: zoom)
            .background(Color.surfaceSunken)
    }

    private var textPane: some View {
        VStack(spacing: 0) {
            statusLine
            Divider()
            textArea
        }
    }

    // MARK: Шапка

    private var header: some View {
        HStack(spacing: Spacing.s) {
            Text(section == .notes ? "Страница \(number)" : "Слайд \(number)").font(.headline)
            Spacer()
            if let note { noteControls(note) }
            if let slide { slideControls(slide) }
            Divider().frame(height: 18)
            rerecognizeButton
            Button {
                flushSave()
                showHistory = true
            } label: {
                Label("История", systemImage: "clock.arrow.circlepath")
            }
            .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                HistoryPopover(entries: PageTextStore(paths: paths).history(pageID, in: section).entries(),
                               emptyHint: "Они появляются, когда текст перезаписывается.",
                               subtitle: { describe($0.info(PageText.self)) },
                               restore: { library.restoreVersion($0, pageID: pageID, lectureID: lecture.id) })
            }
        }
        .disabled(busy)
    }

    /// «Распознать заново»; у страницы тетради в меню кнопки — подробное чтение фрагментами.
    @ViewBuilder
    private var rerecognizeButton: some View {
        if section == .notes {
            Menu {
                Button("Распознать подробно") { rerecognize(detailed: true) }
                    .help("Страница читается шестью увеличенными фрагментами (сетка 3×2) одним запросом: лучше мелкие "
                          + "индексы, штрихи и значки, но дольше и расходует больше лимита. Через Claude или Codex.")
            } label: {
                Text("Распознать заново")
            } primaryAction: {
                rerecognize(detailed: false)
            }
            .fixedSize()
            .disabled(isRunning)
            .help("Щелчок — обычное распознавание, стрелка — «Распознать подробно» (через Claude или Codex)")
        } else {
            let textLayer = slide.map { !$0.usesImage } ?? false
            Button("Распознать заново") { rerecognize(detailed: false) }
                .disabled(isRunning || textLayer)
                .help(textLayer ? "Слайд берётся из текстового слоя; переключите режим на «Картинка»" : "")
        }
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
        // Не Toggle: любой Toggle в окне выключает в SwiftUI «Импорт с iPhone» (Камеру непрерывности).
        Button {
            library.setSlideExcluded(!page.excluded, for: page.id, lectureID: lecture.id)
        } label: {
            Label("Не в конспект", systemImage: page.excluded ? "checkmark.square.fill" : "square")
                .labelStyle(.titleAndIcon)
        }
        .accessibilityValue(page.excluded ? "Включено" : "Выключено")
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
        HStack(spacing: Spacing.s) {
            switch recognition.state(of: pageID) {
            case .queued:
                Image(systemName: "clock").accessibilityHidden(true)
                Text("В очереди на распознавание")
            case .running(let engine, let startedAt):
                ProgressView().controlSize(.small)
                Text("Распознаёт \(engine.title)")
                ElapsedText(since: startedAt)
            case .failed(let error):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.statusError)
                    .accessibilityHidden(true)
                Text(error.userMessage).lineLimit(2)
                    .foregroundStyle(.primary)
                    .help(error.details)
                    .accessibilityLabel("Ошибка: \(error.userMessage)")
            case nil:
                provenance
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
    }

    @ViewBuilder
    private var provenance: some View {
        if let info {
            switch info.origin {
            case .model:
                Text("\(info.engine?.title ?? "Модель") · \(info.model ?? "") · \(info.updatedAt.stamp)")
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
                Label("фото изменено после распознавания", systemImage: "arrow.triangle.2.circlepath")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.primary)
            }
        } else {
            Text("Не распознано")
        }
    }

    @ViewBuilder
    private var textArea: some View {
        if info == nil && text.isEmpty && !isRunning {
            VStack(spacing: Spacing.s) {
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

    // MARK: Загрузка и сохранение

    /// Читает текст в фоне: файл может быть выгружен в iCloud, и чтение на главном потоке ждало бы загрузки.
    private func loadText() async {
        guard loadedRevision != revision || text.isEmpty else { return }
        let target = revision
        let loaded = await Self.readText(PageTextStore(paths: paths), pageID: pageID, section: section)
        guard !Task.isCancelled else { return }
        loadedRevision = target
        text = loaded
    }

    @concurrent
    private static func readText(_ store: PageTextStore, pageID: String, section: SourceSection) async -> String {
        store.read(pageID, in: section) ?? ""
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
