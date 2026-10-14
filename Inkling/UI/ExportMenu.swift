import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Меню «Экспорт» лекции (SPEC, раздел 8): конспект в `.md` и PDF A4, карточки для Anki.
struct ExportMenu: View {
    @Environment(Library.self) private var library
    let lecture: LectureRecord
    @State private var askAnki = false
    @State private var includeQuestions = false
    @State private var exporting = false

    private var konspekt: String? { KonspektStore(folder: lecture.folder).read() }
    private var study: StudyMaterials? { StudyStore(folder: lecture.folder).readStudy() }
    private var baseName: String { FolderNaming.lectureFolderName(date: lecture.meta.date, topic: lecture.meta.topic) }

    var body: some View {
        Menu {
            Button("Конспект в Markdown…") { exportMarkdown() }
                .disabled(konspekt == nil)
            Button("Конспект в PDF…") { exportPDF() }
                .disabled(konspekt == nil || exporting)
            Divider()
            Button("Карточки для Anki…") { askAnki = true }
                .disabled(study == nil)
        } label: {
            Label(exporting ? "Экспорт…" : "Экспорт", systemImage: "square.and.arrow.up")
        }
        .help("Экспорт конспекта и карточек")
        .sheet(isPresented: $askAnki) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Карточки для Anki").font(.title2.weight(.semibold))
                Text("Файл с табуляцией для «Файл → Импорт» в Anki. Формулы — в синтаксисе MathJax, теги «предмет::тема». Вопросы с пометкой «ошибка в вопросе» не попадают.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Добавить вопросы с ответами", isOn: $includeQuestions)
                HStack {
                    Spacer()
                    Button("Отмена", role: .cancel) { askAnki = false }.keyboardShortcut(.cancelAction)
                    Button("Сохранить…") {
                        askAnki = false
                        exportAnki()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 440)
        }
    }

    private func savePanel(name: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func exportMarkdown() {
        guard let konspekt, let url = savePanel(name: "\(baseName).md", type: .init(filenameExtension: "md") ?? .plainText)
        else { return }
        do {
            try Data(konspekt.utf8).write(to: url, options: .atomic)
        } catch {
            library.errorMessage = "Не удалось сохранить файл: \(error.localizedDescription)"
        }
    }

    private func exportPDF() {
        guard let konspekt, let url = savePanel(name: "\(baseName).pdf", type: .pdf) else { return }
        exporting = true
        Task {
            defer { exporting = false }
            do {
                try await PDFExporter().export(markdown: konspekt, title: lecture.meta.topic, to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                library.errorMessage = error.localizedDescription
            }
        }
    }

    private func exportAnki() {
        guard let study, let url = savePanel(name: "\(baseName) — Anki.csv", type: .commaSeparatedText) else { return }
        let text = AnkiExporter.export(study, progress: StudyStore(folder: lecture.folder).readProgress(),
                                       subject: lecture.meta.subject, topic: lecture.meta.topic,
                                       includeQuestions: includeQuestions)
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            library.errorMessage = "Не удалось сохранить файл: \(error.localizedDescription)"
        }
    }
}
