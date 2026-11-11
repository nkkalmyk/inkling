import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: Лента миниатюр

struct ThumbnailStrip: View {
    @Environment(Library.self) private var library
    @Environment(\.undoManager) private var undoManager
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
        .onDeleteCommand { library.requestDeletePages(selection, lectureID: lecture.id) }
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
        library.movePages(moved, before: before, in: section, lectureID: lecture.id, undoManager: undoManager)
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
            Button("Удалить страницы (\(ids.count))…", role: .destructive) {
                library.requestDeletePages(ids, lectureID: lecture.id)
            }
        }
    }
}

/// Заголовок раздела ленты: название, число страниц, «+» с меню «Добавить файлы…» и «Импорт с iPhone»
/// (то же меню и по правому щелчку).
struct SectionHeader: View {
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
struct EmptyDropRow: View {
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
struct ThumbnailRow<Thumbnail: View>: View {
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
