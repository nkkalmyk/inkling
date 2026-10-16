import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Вкладка «Источники» (SPEC, разделы 3 и 7), как в Просмотре: слева лента миниатюр «Мой конспект» и «Слайды»
/// с обычным выделением (стрелки, ⇧ и ⌘, Delete), справа выбранная страница с текстом.
struct SourcesView: View {
    @Environment(Library.self) private var library
    let lecture: LectureRecord

    @Environment(\.isActiveTab) private var isActive
    @State private var selection: Set<String> = []
    @State private var activeSection: SourceSection = .notes
    /// Ширина ленты миниатюр, общая для всех лекций.
    @AppStorage("sources.stripWidth") private var stripWidth = 220.0

    var body: some View {
        VStack(spacing: 0) {
            RecognitionBar(lecture: lecture)
            ResizableSplit(leadingWidth: $stripWidth, range: 180...300) {
                ThumbnailStrip(lecture: lecture, selection: $selection, activeSection: $activeSection,
                               addFiles: addFiles)
            } trailing: {
                detail
            }
        }
        // «Импорт с iPhone» (Камера непрерывности): SwiftUI отдаёт снимок этому экрану, он идёт в выбранный раздел.
        .importsItemProviders([.image, .pdf]) { providers in
            guard isActive else { return false }
            library.importProviders(providers, into: activeSection, lectureID: lecture.id)
            return true
        }
        .onPasteCommand(of: ImportStaging.acceptedTypes) { providers in
            guard isActive else { return }
            library.importProviders(providers, into: activeSection, lectureID: lecture.id)
        }
        .onChange(of: isActive, initial: true) { isActive ? updateTarget() : clearTarget() }
        .onChange(of: activeSection) { if isActive { updateTarget() } }
        .onDisappear(perform: clearTarget)
        .onChange(of: selection) {
            if let first = selection.first, let location = lecture.meta.page(first) { activeSection = location.section }
        }
        .onChange(of: lecture.meta) {
            selection = selection.filter { lecture.meta.page($0) != nil }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if selection.count > 1 {
            EmptyState("Выбрано страниц: \(selection.count)", systemImage: "square.stack",
                       description: "Перетащите их в ленте, чтобы изменить порядок, или удалите клавишей ⌫.") {
                Button("Удалить выбранные", role: .destructive) { deletePages(selection) }
            }
        } else {
            PageDetailView(lecture: lecture, pageID: selection.first)
        }
    }

    private func updateTarget() {
        library.importTarget = (lecture.id, activeSection)
    }

    /// Камера непрерывности и меню «Импорт с iPhone» кладут файлы, только пока «Источники» на экране.
    private func clearTarget() {
        if library.importTarget?.lectureID == lecture.id { library.importTarget = nil }
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

    private func deletePages(_ ids: Set<String>) {
        for section in SourceSection.allCases {
            let inSection = ids.filter { lecture.meta.page($0)?.section == section }
            if !inSection.isEmpty { library.deletePages(inSection, in: section, lectureID: lecture.id) }
        }
    }
}

// MARK: Лента миниатюр

private struct ThumbnailStrip: View {
    @Environment(Library.self) private var library
    let lecture: LectureRecord
    @Binding var selection: Set<String>
    @Binding var activeSection: SourceSection
    let addFiles: (SourceSection) -> Void

    private var paths: LecturePaths { LecturePaths(folder: lecture.folder) }

    var body: some View {
        List(selection: $selection) {
            ForEach(SourceSection.allCases) { section in
                Section {
                    rows(section)
                    if pageIDs(section).isEmpty {
                        EmptyDropRow(section: section, onOpen: { activeSection = section },
                                     addFiles: { addFiles(section) }) { pasteboard in
                            activeSection = section
                            library.importPasteboard(pasteboard, into: section, lectureID: lecture.id)
                        }
                        .onDrop(of: ImportStaging.acceptedTypes, isTargeted: nil) { providers in
                            activeSection = section
                            library.importProviders(providers, into: section, lectureID: lecture.id)
                            return true
                        }
                        .selectionDisabled()
                    }
                } header: {
                    SectionHeader(section: section, count: pageIDs(section).count, isActive: activeSection == section,
                                  onOpen: { activeSection = section }, addFiles: { addFiles(section) }) { pasteboard in
                        activeSection = section
                        library.importPasteboard(pasteboard, into: section, lectureID: lecture.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // Без материала сайдбара: в macOS 26 он продлевается под тулбар, и граница ленты
        // прочерчивала линию через переключатель разделов.
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { ids in
            menu(for: ids)
        }
        .onDeleteCommand {
            for section in SourceSection.allCases {
                let ids = selection.filter { lecture.meta.page($0)?.section == section }
                if !ids.isEmpty { library.deletePages(ids, in: section, lectureID: lecture.id) }
            }
        }
    }

    private func pageIDs(_ section: SourceSection) -> [String] {
        switch section {
        case .notes: lecture.meta.notes.map(\.id)
        case .slides: lecture.meta.slides.map(\.id)
        }
    }

    @ViewBuilder
    private func rows(_ section: SourceSection) -> some View {
        switch section {
        case .notes:
            ForEach(Array(lecture.meta.notes.enumerated()), id: \.element.id) { index, page in
                ThumbnailRow(id: page.id, number: index + 1, lecture: lecture) {
                    NotePageThumbnail(page: page, paths: paths)
                }
            }
            .onMove { move($0, to: $1, in: .notes) }
            .onInsert(of: ImportStaging.acceptedTypes) { _, providers in importDropped(providers, into: .notes) }
        case .slides:
            ForEach(Array(lecture.meta.slides.enumerated()), id: \.element.id) { index, page in
                ThumbnailRow(id: page.id, number: index + 1, lecture: lecture) {
                    SlidePageThumbnail(page: page, paths: paths)
                }
            }
            .onMove { move($0, to: $1, in: .slides) }
            .onInsert(of: ImportStaging.acceptedTypes) { _, providers in importDropped(providers, into: .slides) }
        }
    }

    /// Перестановка в ленте: страницы встают перед той, что была на месте назначения.
    private func move(_ offsets: IndexSet, to destination: Int, in section: SourceSection) {
        let order = pageIDs(section)
        let moved = offsets.map { order[$0] }
        let before = order[destination...].first { !moved.contains($0) }
        library.movePages(moved, before: before, in: section, lectureID: lecture.id)
    }

    /// Файлы из Finder добавляются в конец раздела, как при «Добавить файлы…».
    private func importDropped(_ providers: [NSItemProvider], into section: SourceSection) {
        activeSection = section
        library.importProviders(providers, into: section, lectureID: lecture.id)
    }

    @ViewBuilder
    private func menu(for ids: Set<String>) -> some View {
        if ids.count == 1, let id = ids.first {
            if let note = lecture.meta.notes.first(where: { $0.id == id }) {
                NotePageMenu(page: note, lecture: lecture)
            } else if let slide = lecture.meta.slides.first(where: { $0.id == id }) {
                SlidePageMenu(page: slide, lecture: lecture)
            }
        } else if ids.count > 1 {
            Button("Удалить страницы (\(ids.count))", role: .destructive) {
                for section in SourceSection.allCases {
                    let inSection = ids.filter { lecture.meta.page($0)?.section == section }
                    if !inSection.isEmpty { library.deletePages(inSection, in: section, lectureID: lecture.id) }
                }
            }
        }
    }
}

/// Заголовок раздела ленты: название, число страниц, «+» с меню «Добавить файлы…» и «Импорт с iPhone»
/// (то же меню и по правому щелчку).
private struct SectionHeader: View {
    let section: SourceSection
    let count: Int
    let isActive: Bool
    let onOpen: () -> Void
    let addFiles: () -> Void
    let onImport: (NSPasteboard) -> Void

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Text(section.title)
            if count > 0 {
                Text("\(count)").foregroundStyle(.tertiary).monospacedDigit()
            }
            Spacer()
            ContinuityCameraButton(onOpen: onOpen, onAddFiles: addFiles, onImport: onImport)
                .fixedSize()
        }
        .background { ContinuityCameraAnchor(onAddFiles: addFiles, onImport: onImport) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isActive ? "\(section.title), сюда добавляются новые файлы" : section.title)
    }
}

/// Пустой раздел: куда перетащить файлы и как ещё их добавить.
private struct EmptyDropRow: View {
    let section: SourceSection
    let onOpen: () -> Void
    let addFiles: () -> Void
    let onImport: (NSPasteboard) -> Void

    var body: some View {
        VStack(spacing: Spacing.xs) {
            Image(systemName: section == .notes ? "camera.on.rectangle" : "rectangle.on.rectangle")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(section == .notes ? "Перетащите сюда фото рукописи или PDF-скан" : "Перетащите сюда PDF со слайдами")
                .font(.callout)
            Text("Или ⌘V, или снимите на iPhone:")
                .font(.caption)
                .foregroundStyle(.secondary)
            ContinuityCameraButton(title: "Добавить…", onOpen: onOpen, onAddFiles: addFiles, onImport: onImport)
                .fixedSize()
                .padding(.top, Spacing.xxs)
        }
        .multilineTextAlignment(.center)
        .padding(.vertical, Spacing.m)
        .frame(maxWidth: .infinity, minHeight: 120)
        .surface(.sunken, radius: Radius.control)
        .background { ContinuityCameraAnchor(onAddFiles: addFiles, onImport: onImport) }
    }
}

/// Строка ленты: миниатюра с состоянием распознавания и номер.
private struct ThumbnailRow<Thumbnail: View>: View {
    @Environment(Library.self) private var library
    let id: String
    let number: Int
    let lecture: LectureRecord
    @ViewBuilder let thumbnail: () -> Thumbnail

    var body: some View {
        VStack(spacing: Spacing.xs) {
            // Значок — в углу самой картинки, а не строки: фото уже ленты и стоит по центру.
            thumbnail()
                .frame(maxHeight: 180)
                .overlay(alignment: .bottomLeading) { RecognitionBadge(pageID: id, lecture: lecture) }
                .overlay {
                    if library.busyPages.contains(id) {
                        ProgressView().controlSize(.small)
                            .padding(Spacing.s)
                            .background(.regularMaterial, in: RoundedRectangle.ds(Radius.control))
                    }
                }
                .frame(maxWidth: .infinity)
            Text("\(number)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Страница \(number)")
    }
}

// MARK: Миниатюры

private struct NotePageThumbnail: View {
    @Environment(Library.self) private var library
    let page: NotePage
    let paths: LecturePaths

    var body: some View {
        PageImageView(source: paths.imageSource(for: page), maxPixel: 480,
                      revision: library.pageRevisions[page.id] ?? 0)
            .clipShape(RoundedRectangle.ds(Radius.control))
            .overlay(alignment: .topTrailing) {
                if case .original = page.crop, !page.source.isPDF {
                    Chip("Оригинал", style: .overlay).padding(Spacing.xs)
                }
            }
    }
}

private struct SlidePageThumbnail: View {
    @Environment(Library.self) private var library
    let page: SlidePage
    let paths: LecturePaths

    var body: some View {
        PageImageView(source: paths.imageSource(for: page), maxPixel: 480,
                      revision: library.pageRevisions[page.id] ?? 0)
            .clipShape(RoundedRectangle.ds(Radius.control))
            .opacity(page.excluded ? 0.35 : 1)
            .overlay(alignment: .topTrailing) {
                VStack(alignment: .trailing, spacing: Spacing.xxs) {
                    Chip(page.usesImage ? "Картинка" : "Текст", style: .overlay)
                    if page.excluded { Chip("Не в конспекте", style: .overlay) }
                }
                .padding(Spacing.xs)
            }
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
        // Не Toggle: любой Toggle в окне выключает в SwiftUI «Импорт с iPhone» (Камеру непрерывности).
        Button {
            library.setSlideExcluded(!page.excluded, for: page.id, lectureID: lecture.id)
        } label: {
            if page.excluded {
                Label("Не включать в конспект", systemImage: "checkmark")
            } else {
                Text("Не включать в конспект")
            }
        }
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

/// Значок состояния текста на миниатюре. Цвет только у ошибки; остальное — значок с подписью.
private struct RecognitionBadge: View {
    @Environment(RecognitionCenter.self) private var recognition
    let pageID: String
    let lecture: LectureRecord

    var body: some View {
        Group {
            switch recognition.state(of: pageID) {
            case .queued:
                StatusSymbol(systemImage: "clock", label: "В очереди", onImage: true)
            case .running:
                ProgressView().controlSize(.mini).padding(Spacing.xs)
                    .background(.regularMaterial, in: Circle())
                    .accessibilityLabel("Распознаётся")
            case .failed(let error):
                StatusSymbol(systemImage: "exclamationmark.triangle.fill", label: error.userMessage,
                             tint: .statusError, onImage: true)
            case nil:
                if let note = lecture.meta.notes.first(where: { $0.id == pageID }) {
                    if note.text == nil {
                        StatusSymbol(systemImage: "text.badge.xmark", label: "Не распознано", onImage: true)
                    } else if note.textIsStale {
                        StatusSymbol(systemImage: "arrow.triangle.2.circlepath", label: "Фото изменено после распознавания",
                                     onImage: true)
                    } else if note.text?.manuallyEdited == true {
                        StatusSymbol(systemImage: "pencil", label: "Текст правлен вручную", onImage: true)
                    }
                } else if let slide = lecture.meta.slides.first(where: { $0.id == pageID }), slide.needsRecognition {
                    StatusSymbol(systemImage: "text.badge.xmark", label: "Не распознано", onImage: true)
                }
            }
        }
        .padding(Spacing.xs)
    }
}
