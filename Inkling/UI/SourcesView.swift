import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Вкладка «Источники» (SPEC, разделы 3 и 7): «Мой конспект» и «Слайды», импорт, порядок, обрезка, режим слайдов.
struct SourcesView: View {
    @Environment(Library.self) private var library
    let lecture: LectureRecord
    var showNotes: () -> Void = {}

    @State private var selection: String?
    @State private var activeSection: SourceSection = .notes

    private var paths: LecturePaths { LecturePaths(folder: lecture.folder) }

    var body: some View {
        VStack(spacing: 0) {
            RecognitionBar(lecture: lecture)
            content
        }
    }

    private var content: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(SourceSection.allCases) { section in
                        SourceSectionView(lecture: lecture, section: section, selection: $selection,
                                          activeSection: $activeSection, addFiles: { addFiles(to: section) })
                    }
                }
                .padding(16)
            }
            .frame(minWidth: 320, idealWidth: 460)

            PageDetailView(lecture: lecture, pageID: selection)
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onPasteCommand(of: ImportStaging.acceptedTypes) { providers in
            library.importProviders(providers, into: activeSection, lectureID: lecture.id)
        }
        .onDeleteCommand { deleteSelection() }
        .onAppear { updateTarget() }
        .onChange(of: activeSection) { updateTarget() }
        .onDisappear {
            if library.importTarget?.lectureID == lecture.id { library.importTarget = nil }
        }
        .onChange(of: lecture.meta) {
            if let selection, lecture.meta.page(selection) == nil { self.selection = nil }
        }
    }

    private func updateTarget() {
        library.importTarget = (lecture.id, activeSection)
    }

    private func addFiles(to section: SourceSection) {
        activeSection = section
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.jpeg, .png, .heic, .heif, .tiff, .pdf]
        panel.prompt = "Добавить"
        panel.message = section == .notes ? "Фото рукописи или PDF-сканы тетради" : "PDF со слайдами"
        guard panel.runModal() == .OK else { return }
        library.importFiles(panel.urls, into: section, lectureID: lecture.id)
    }

    private func deleteSelection() {
        guard let selection, let location = lecture.meta.page(selection) else { return }
        library.deletePages([selection], in: location.section, lectureID: lecture.id)
    }
}

// MARK: Раздел

private struct SourceSectionView: View {
    @Environment(Library.self) private var library
    let lecture: LectureRecord
    let section: SourceSection
    @Binding var selection: String?
    @Binding var activeSection: SourceSection
    let addFiles: () -> Void

    @State private var isTargeted = false

    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 180), spacing: 12)]
    private var paths: LecturePaths { LecturePaths(folder: lecture.folder) }

    private var pageIDs: [String] {
        switch section {
        case .notes: lecture.meta.notes.map(\.id)
        case .slides: lecture.meta.slides.map(\.id)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if pageIDs.isEmpty {
                emptyDropZone
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    switch section {
                    case .notes:
                        ForEach(Array(lecture.meta.notes.enumerated()), id: \.element.id) { index, page in
                            cell(id: page.id, number: index + 1) { NotePageCell(page: page, paths: paths) }
                                .contextMenu { NotePageMenu(page: page, lecture: lecture) }
                        }
                    case .slides:
                        ForEach(Array(lecture.meta.slides.enumerated()), id: \.element.id) { index, page in
                            cell(id: page.id, number: index + 1) { SlidePageCell(page: page, paths: paths) }
                                .contextMenu { SlidePageMenu(page: page, lecture: lecture) }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
                ContinuityCameraAnchor(onAddFiles: addFiles) { pasteboard in
                    activeSection = section
                    library.importPasteboard(pasteboard, into: section, lectureID: lecture.id)
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(activeSection == section ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1)
        }
        .onDrop(of: ImportStaging.acceptedTypes, isTargeted: $isTargeted) { providers in
            activeSection = section
            library.importProviders(providers, into: section, lectureID: lecture.id)
            return true
        }
        .onTapGesture { activeSection = section }
    }

    private var header: some View {
        HStack {
            Text(section.title).font(.headline)
            if !pageIDs.isEmpty {
                Text("\(pageIDs.count)").foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                addFiles()
            } label: {
                Label("Добавить файлы…", systemImage: "plus")
            }
            .controlSize(.small)
        }
    }

    private var emptyDropZone: some View {
        VStack(spacing: 6) {
            Image(systemName: section == .notes ? "camera.on.rectangle" : "rectangle.on.rectangle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(section == .notes
                 ? "Перетащите сюда фото рукописи или PDF-скан"
                 : "Перетащите сюда PDF со слайдами")
            Text("Или ⌘V, или правый щелчок → «Импорт с iPhone»")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 110)
        .multilineTextAlignment(.center)
    }

    private func cell<Content: View>(id: String, number: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 4) {
            content()
                .frame(height: 150)
                .overlay(alignment: .bottomLeading) { RecognitionBadge(pageID: id, lecture: lecture) }
                .overlay {
                    if library.busyPages.contains(id) {
                        ProgressView().controlSize(.small)
                            .padding(8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(selection == id ? Color.accentColor : Color.secondary.opacity(0.25),
                                      lineWidth: selection == id ? 3 : 1)
                }
            Text("\(number)").font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selection = id
            activeSection = section
        }
        .draggable(id)
        .dropDestination(for: String.self) { dragged, _ in
            let before = LectureMeta.insertionPoint(order: pageIDs, dragged: dragged, droppedOn: id)
            library.movePages(dragged, before: before, in: section, lectureID: lecture.id)
            return true
        }
    }
}

// MARK: Ячейки

private struct NotePageCell: View {
    @Environment(Library.self) private var library
    let page: NotePage
    let paths: LecturePaths

    var body: some View {
        PageImageView(source: paths.imageSource(for: page), maxPixel: 360,
                      revision: library.pageRevisions[page.id] ?? 0)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topTrailing) {
                if case .original = page.crop, !page.source.isPDF {
                    Badge(text: "Оригинал")
                }
            }
    }
}

private struct SlidePageCell: View {
    @Environment(Library.self) private var library
    let page: SlidePage
    let paths: LecturePaths

    var body: some View {
        PageImageView(source: paths.imageSource(for: page), maxPixel: 360,
                      revision: library.pageRevisions[page.id] ?? 0)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .opacity(page.excluded ? 0.35 : 1)
            .overlay(alignment: .topTrailing) {
                VStack(alignment: .trailing, spacing: 3) {
                    Badge(text: page.usesImage ? "Картинка" : "Текст")
                    if page.excluded { Badge(text: "Не в конспекте") }
                }
            }
    }
}

private struct Badge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
            .padding(4)
    }
}

// MARK: Меню

struct NotePageMenu: View {
    @Environment(Library.self) private var library
    let page: NotePage
    let lecture: LectureRecord

    var body: some View {
        Button("Повернуть влево") { library.rotateNote(page.id, by: -1, lectureID: lecture.id) }
        Button("Повернуть вправо") { library.rotateNote(page.id, by: 1, lectureID: lecture.id) }
        Divider()
        if case .original = page.crop {
            Button("Автообрезка") { library.setCrop(.auto(nil), forNote: page.id, lectureID: lecture.id) }
        } else {
            Button("Использовать оригинал") { library.setCrop(.original, forNote: page.id, lectureID: lecture.id) }
        }
        Divider()
        Button("Показать оригинал в Finder") {
            library.revealInFinder(LecturePaths(folder: lecture.folder).original(page.source, in: .notes))
        }
        Button("Удалить страницу", role: .destructive) {
            library.deletePages([page.id], in: .notes, lectureID: lecture.id)
        }
    }
}

struct SlidePageMenu: View {
    @Environment(Library.self) private var library
    let page: SlidePage
    let lecture: LectureRecord

    var body: some View {
        if page.source.isPDF {
            Picker("Распознавание", selection: Binding(
                get: { page.mode },
                set: { library.setSlideMode($0, for: page.id, lectureID: lecture.id) })) {
                Text(autoTitle).tag(SlideMode.auto)
                Text("Текстовый слой").tag(SlideMode.textLayer)
                Text("Распознать как картинку").tag(SlideMode.image)
            }
        }
        Toggle("Не включать в конспект", isOn: Binding(
            get: { page.excluded },
            set: { library.setSlideExcluded($0, for: page.id, lectureID: lecture.id) }))
        Divider()
        Button("Удалить слайд", role: .destructive) {
            library.deletePages([page.id], in: .slides, lectureID: lecture.id)
        }
    }

    private var autoTitle: String {
        page.heuristicNeedsImage ? "Автоматически (картинка)" : "Автоматически (текстовый слой)"
    }
}

// MARK: Распознавание

/// Ошибка, остановившая очередь распознавания (нет входа, лимит, нет движка). Прогресс показывает тулбар.
private struct RecognitionBar: View {
    @Environment(RecognitionCenter.self) private var recognition
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let lecture: LectureRecord

    var body: some View {
        VStack(spacing: 0) {
            if let error = recognition.blockingError, recognition.batches[lecture.id] == nil {
                InlineNotice(.error, error.userMessage, systemImage: "exclamationmark.octagon.fill",
                             details: error.details, dismiss: { recognition.blockingError = nil }) {
                    if case .rateLimited = error {} else {
                        Button("Настройки…") { openSettings() }
                    }
                    if !pending.isEmpty {
                        Button("Повторить") { recognition.recognize(lectureID: lecture.id, pageIDs: pending) }
                    }
                }
                .transition(.notice(reduceMotion: reduceMotion))
                Divider()
            }
        }
        .motion(.standard, value: recognition.blockingError == nil)
    }

    private var pending: [String] { recognition.pendingPages(in: lecture) }
}

/// Значок состояния текста на миниатюре.
private struct RecognitionBadge: View {
    @Environment(RecognitionCenter.self) private var recognition
    let pageID: String
    let lecture: LectureRecord

    var body: some View {
        Group {
            switch recognition.state(of: pageID) {
            case .queued:
                icon("clock", .secondary, "В очереди")
            case .running:
                ProgressView().controlSize(.mini).padding(4)
                    .background(.regularMaterial, in: Circle())
            case .failed(let error):
                icon("exclamationmark.triangle.fill", .red, error.userMessage)
            case nil:
                if let note = lecture.meta.notes.first(where: { $0.id == pageID }) {
                    if note.text == nil { icon("text.badge.xmark", .secondary, "Не распознано") }
                    else if note.textIsStale { icon("exclamationmark.circle.fill", .orange, "Фото изменено после распознавания") }
                    else if note.text?.manuallyEdited == true { icon("pencil.circle.fill", .blue, "Текст правлен вручную") }
                } else if let slide = lecture.meta.slides.first(where: { $0.id == pageID }), slide.needsRecognition {
                    icon("text.badge.xmark", .secondary, "Не распознано")
                }
            }
        }
        .padding(4)
    }

    private func icon(_ name: String, _ style: Color, _ help: String) -> some View {
        Image(systemName: name)
            .font(.caption)
            .foregroundStyle(style)
            .padding(3)
            .background(.regularMaterial, in: Circle())
            .help(help)
    }
}
