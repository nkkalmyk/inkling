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
    /// Когда начался экспорт HTML; `nil` — не идёт.
    private(set) var exportingHTMLSince: Date?
    /// Дописывает отложенную правку конспекта в файл до чтения (`NotesFlush`).
    var flushEdits: (() -> Void)?

    init(library: Library, lecture: LectureRecord) {
        self.library = library
        self.lecture = lecture
    }

    func update(_ lecture: LectureRecord) { self.lecture = lecture }

    /// По метаданным лекции, без чтения файлов: тулбар и меню спрашивают это на каждую перерисовку.
    var hasKonspekt: Bool { lecture.meta.konspekt != nil }
    var hasStudy: Bool { lecture.meta.study != nil }

    private var konspekt: String? {
        flushEdits?()
        return KonspektStore(folder: lecture.folder).read()
    }
    private var study: StudyMaterials? { StudyStore(folder: lecture.folder).readStudy() }
    private var baseName: String { FolderNaming.lectureFolderName(date: lecture.meta.date, topic: lecture.meta.topic) }

    func exportMarkdown() {
        guard let konspekt, let url = savePanel(name: "\(baseName).md", type: .init(filenameExtension: "md") ?? .plainText)
        else { return }
        write(MarkdownExporter.document(konspekt: konspekt, subject: lecture.meta.subject, topic: lecture.meta.topic,
                                        date: lecture.meta.date), to: url)
    }

    /// «Скопировать для чата»: шаблон `chat-handoff.md` и весь конспект — в буфер обмена, чтобы вставить в любой чат
    /// в браузере (когда движки упёрлись в лимит). Сети нет: только буфер.
    func copyForChat() {
        guard let konspekt else { return }
        let template: String
        do {
            template = try library.prompts.template(Self.chatTemplate)
        } catch {
            library.errorMessage = error.localizedDescription
            return
        }
        let text = Self.chatPrompt(template: template, konspekt: konspekt, subject: lecture.meta.subject, topic: lecture.meta.topic)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        // Как у «Скопировать» в системе — без уведомления на экране; VoiceOver сообщает, что получилось.
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "Конспект скопирован для чата", .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    nonisolated static let chatTemplate = "chat-handoff.md"

    nonisolated static func chatPrompt(template: String, konspekt: String, subject: String, topic: String) -> String {
        PromptLibrary.render(template, values: ["предмет": subject, "тема": topic,
                                                "конспект": konspekt.trimmingCharacters(in: .whitespacesAndNewlines)])
    }

    func exportPDF() {
        guard exportingPDFSince == nil, let konspekt else { return }
        exportPDF(markdown: konspekt, baseName: ExportLocation.pdfBaseName(
            subject: lecture.meta.subject, topic: lecture.meta.topic, date: lecture.meta.date))
    }

    /// Конспект одним HTML-файлом рядом с PDF: открывается офлайн в любом браузере (`HTMLExporter`).
    func exportHTML() {
        guard exportingHTMLSince == nil, let konspekt else { return }
        let meta = lecture.meta
        let url: URL
        do {
            url = try ExportLocation.htmlURL(baseName: ExportLocation.pdfBaseName(subject: meta.subject, topic: meta.topic,
                                                                                    date: meta.date), subject: meta.subject)
        } catch {
            library.errorMessage = "Не удалось создать папку «\(ExportLocation.pdfFolderName)/"
                + "\(ExportLocation.subjectFolderName(meta.subject))»: \(error.localizedDescription)"
            return
        }
        exportingHTMLSince = .now
        let heading = PrintHeading(subject: meta.subject, topic: meta.topic, date: meta.date.formatted)
        Task {
            defer { exportingHTMLSince = nil }
            do {
                let rendered = try await NotesRenderer().render(markdown: konspekt, heading: heading)
                try HTMLExporter.write(title: "\(meta.topic) — \(meta.subject)",
                                       sections: [.init(id: "lecture", title: meta.topic, rendered: rendered)], to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                library.errorMessage = error.localizedDescription
            }
        }
    }

    /// Шпаргалка по конспекту: определения, законы и формулы подряд (без вызовов модели).
    func exportCheatSheet() {
        guard exportingPDFSince == nil, let konspekt else { return }
        guard let sheet = CheatSheet.build(from: konspekt, subject: lecture.meta.subject, topic: lecture.meta.topic) else {
            library.errorMessage = "В конспекте нет определений, законов и вынесенных формул для шпаргалки."
            return
        }
        exportPDF(markdown: sheet, baseName: ExportLocation.cheatSheetBaseName(
            subject: lecture.meta.subject, topic: lecture.meta.topic, date: lecture.meta.date))
    }

    private func exportPDF(markdown konspekt: String, baseName: String) {
        // PDF сразу падает в «Документы → Конспекты → <предмет>», без панели сохранения.
        let url: URL
        do {
            url = try ExportLocation.pdfURL(baseName: baseName, subject: lecture.meta.subject)
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

/// Пункты экспорта для меню «…». Конспект в PDF — отдельной кнопкой «PDF» в тулбаре. Порядок и отключение — как в
/// «Лекция → Экспорт»: пока конспект пересобирается (`available == false`), его производные не экспортируются.
struct ExportMenuItems: View {
    let export: ExportController
    var available: Bool

    var body: some View {
        Button("Шпаргалка в PDF") { export.exportCheatSheet() }
            .disabled(!available || export.exportingPDFSince != nil)
            .help("Определения, законы, теоремы и формулы конспекта подряд на одном листе")
        Button("Конспект в HTML") { export.exportHTML() }
            .disabled(!available || export.exportingHTMLSince != nil)
            .help("Один файл со стилями и формулами: открывается без интернета в любом браузере, на телефоне и в Windows")
        Button("Конспект в Markdown…") { export.exportMarkdown() }
            .disabled(!export.hasKonspekt)
        Button("Карточки для Anki…") { export.askAnki = true }
            .disabled(!export.hasStudy)
        Divider()
        Button("Скопировать для чата") { export.copyForChat() }
            .disabled(!export.hasKonspekt)
            .help("Конспект с короткой просьбой к репетитору — в буфер обмена, для ChatGPT, Claude или другого чата в браузере")
    }
}

/// Кнопка «PDF» в тулбаре — самый частый экспорт: конспект сразу уходит в PDF. Видна, когда конспект собран.
/// Кнопка, а не `Menu` с вариантами: меню в тулбаре macOS 26 акцентную заливку не принимает (проверено),
/// а яркой «PDF» бывает часто. Шпаргалка и Markdown — в «…».
struct PDFExportButton: View {
    let export: ExportController
    var prominent: Bool
    /// Пока конспект пересобирается, экспортировать нечего.
    var available: Bool

    var body: some View {
        Button { export.exportPDF() } label: {
            Label("PDF", systemImage: "doc.richtext")
                .labelStyle(.titleAndIcon)
        }
        .prominentAction(prominent)
        .disabled(!available || export.exportingPDFSince != nil)
        .help("Конспект в PDF (⌘P)")
        .accessibilityLabel("Конспект в PDF")
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
