import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Вкладка «Источники» (SPEC, разделы 3 и 7), как в Просмотре: слева лента миниатюр «Мой конспект» и «Слайды»
/// с обычным выделением (стрелки, ⇧ и ⌘, Delete), справа выбранная страница с текстом.
struct SourcesView: View {
    @Environment(Library.self) private var library
    let lecture: LectureRecord

    @Environment(\.isActiveTab) private var isActive
    @Environment(\.lectureRequests) private var requests
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
        .task(id: requests.wrappedValue.addFiles && isActive) {
            guard requests.wrappedValue.addFiles, isActive else { return }
            requests.wrappedValue.addFiles = false
            addFiles(to: activeSection)
        }
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
                Button("Удалить выбранные…", role: .destructive) { deletePages(selection) }
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
        library.requestDeletePages(ids, lectureID: lecture.id)
    }
}
