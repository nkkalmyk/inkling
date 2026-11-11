import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
