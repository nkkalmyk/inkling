import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Экспорт лекции (SPEC, раздел 8): конспект в `.md` и PDF A4, карточки для Anki.
/// Действия общие для меню «…» в тулбаре и меню «Лекция» в строке меню.
@MainActor
@Observable
final class ExportController {
    private let library: Library
    private(set) var lecture: LectureRecord
    /// Лист «Карточки для Anki».
    var askAnki = false
    var includeQuestions = false
    /// Когда начался экспорт PDF; `nil` — не идёт.
    private(set) var exportingPDFSince: Date?

    init(library: Library, lecture: LectureRecord) {
        self.library = library
        self.lecture = lecture
    }

    func update(_ lecture: LectureRecord) { self.lecture = lecture }

    /// По метаданным лекции, без чтения файлов: тулбар и меню спрашивают это на каждую перерисовку.
    var hasKonspekt: Bool { lecture.meta.konspekt != nil }
    var hasStudy: Bool { lecture.meta.study != nil }

    private var konspekt: String? { KonspektStore(folder: lecture.folder).read() }
    private var study: StudyMaterials? { StudyStore(folder: lecture.folder).readStudy() }
    private var baseName: String { FolderNaming.lectureFolderName(date: lecture.meta.date, topic: lecture.meta.topic) }

    func exportMarkdown() {
        guard let konspekt, let url = savePanel(name: "\(baseName).md", type: .init(filenameExtension: "md") ?? .plainText)
        else { return }
        write(MarkdownExporter.document(konspekt: konspekt, subject: lecture.meta.subject, topic: lecture.meta.topic,
                                        date: lecture.meta.date), to: url)
    }

    func exportPDF() {
        guard exportingPDFSince == nil, let konspekt else { return }
        // PDF сразу падает в «Документы → Конспекты → <предмет>», без панели сохранения.
        let url: URL
        do {
            url = try ExportLocation.pdfURL(baseName: ExportLocation.pdfBaseName(
                subject: lecture.meta.subject, topic: lecture.meta.topic, date: lecture.meta.date),
                subject: lecture.meta.subject)
        } catch {
            library.errorMessage = "Не удалось создать папку «\(ExportLocation.pdfFolderName)/"
                + "\(ExportLocation.subjectFolderName(lecture.meta.subject))»: \(error.localizedDescription)"
            return
        }
        exportingPDFSince = .now
        let title = lecture.meta.topic
        let heading = PrintHeading(subject: lecture.meta.subject, topic: lecture.meta.topic,
                                   date: lecture.meta.date.formatted)
        Task {
            defer { exportingPDFSince = nil }
            do {
                try await PDFExporter().export(markdown: konspekt, title: title, heading: heading, to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                library.errorMessage = error.localizedDescription
            }
        }
    }

    func exportAnki() {
        guard let study, let url = savePanel(name: "\(baseName) — Anki.csv", type: .commaSeparatedText) else { return }
        let text = AnkiExporter.export(study, progress: StudyStore(folder: lecture.folder).readProgress(),
                                       subject: lecture.meta.subject, topic: lecture.meta.topic,
                                       includeQuestions: includeQuestions)
        write(text, to: url)
    }

    private func savePanel(name: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func write(_ text: String, to url: URL) {
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            library.errorMessage = "Не удалось сохранить файл: \(error.localizedDescription)"
        }
    }
}

/// Пункты экспорта для меню «…».
struct ExportMenuItems: View {
    let export: ExportController

    var body: some View {
        Button("Конспект в Markdown…") { export.exportMarkdown() }
            .disabled(!export.hasKonspekt)
        Button("Конспект в PDF") { export.exportPDF() }
            .disabled(!export.hasKonspekt || export.exportingPDFSince != nil)
        Button("Карточки для Anki…") { export.askAnki = true }
            .disabled(!export.hasStudy)
    }
}

/// Лист «Карточки для Anki».
struct AnkiExportSheet: View {
    @Bindable var export: ExportController

    var body: some View {
        FormSheet(title: "Карточки для Anki",
                  subtitle: "Файл с табуляцией для «Файл → Импорт» в Anki. Формулы — в синтаксисе MathJax, "
                      + "теги «предмет::тема». Вопросы с пометкой «ошибка в вопросе» не попадают.",
                  confirmTitle: "Сохранить…",
                  confirm: {
                      // Лист закрывается до панели сохранения, иначе панель ляжет поверх листа.
                      Task { export.exportAnki() }
                      return true
                  }) {
            // Не Toggle: любой Toggle в окне выключает в SwiftUI «Импорт с iPhone» (Камеру непрерывности).
            Picker("Что сохранить", selection: $export.includeQuestions) {
                Text("Только карточки").tag(false)
                Text("Карточки и вопросы с ответами").tag(true)
            }
            .pickerStyle(.radioGroup)
        }
    }
}
