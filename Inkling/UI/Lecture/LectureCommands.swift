import SwiftUI

// MARK: Команды строки меню

/// Действия лекции для строки меню. `nil` — пункт недоступен.
struct LectureCommands {
    var tab: Binding<LectureTab>
    var primary: LecturePrimaryAction?
    var perform: (LecturePrimaryAction) -> Void
    var reviewCards: (() -> Void)?
    var exportMarkdown: (() -> Void)?
    var exportPDF: (() -> Void)?
    var exportCheatSheet: (() -> Void)?
    var exportHTML: (() -> Void)?
    var exportAnki: (() -> Void)?
    var copyForChat: (() -> Void)?
    var previousLecture: (() -> Void)?
    var nextLecture: (() -> Void)?
    var edit: () -> Void
    var reveal: () -> Void
    var addFiles: () -> Void
    var delete: () -> Void
    /// Остановить распознавание, сборку и подготовку материалов лекции; `nil`, если ничего не идёт.
    var cancelWork: (() -> Void)?
}

/// Отложенное сохранение правки конспекта (`NotesView` пишет файл через 0,8 с после ввода). Экспорт
/// читает файл, поэтому сначала дописывает правку: иначе в PDF ушёл бы текст без последних слов.
@MainActor
final class NotesFlush {
    var action: (() -> Void)?
    func callAsFunction() { action?() }
}

extension EnvironmentValues {
    @Entry var notesFlush: NotesFlush?
}

/// Отложенные сохранения всех открытых редакторов (конспект, текст страницы). При выходе приложения их дописывает
/// `AppDelegate`: иначе правка, сделанная меньше чем за 0,8 с до ⌘Q, терялась молча.
@MainActor
enum PendingEdits {
    private static var flushes: [UUID: () -> Void] = [:]

    static func register(_ id: UUID, flush: @escaping () -> Void) { flushes[id] = flush }
    static func unregister(_ id: UUID) { flushes[id] = nil }
    static func flushAll() { for flush in flushes.values { flush() } }
}

extension FocusedValues {
    @Entry var lectureCommands: LectureCommands?
    /// Режим «Правка» конспекта, когда открыта вкладка «Конспект».
    @Entry var notesEditing: Binding<Bool>?
}

/// Меню «Лекция».
struct LectureMenuCommands: View {
    @FocusedValue(\.lectureCommands) private var commands

    var body: some View {
        Button(commands?.primary?.title ?? "Следующий шаг") {
            if let commands, let primary = commands.primary { commands.perform(primary) }
        }
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(commands?.primary == nil)
        Button("Повторить карточки") { commands?.reviewCards?() }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(commands?.reviewCards == nil)
        Divider()
        Button("Предыдущая лекция") { commands?.previousLecture?() }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(commands?.previousLecture == nil)
        Button("Следующая лекция") { commands?.nextLecture?() }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(commands?.nextLecture == nil)
        Divider()
        Menu("Экспорт") {
            Button("Конспект в PDF") { commands?.exportPDF?() }
                .disabled(commands?.exportPDF == nil)
            Button("Шпаргалка в PDF") { commands?.exportCheatSheet?() }
                .disabled(commands?.exportCheatSheet == nil)
            Button("Конспект в HTML") { commands?.exportHTML?() }
                .disabled(commands?.exportHTML == nil)
            Button("Конспект в Markdown…") { commands?.exportMarkdown?() }
                .disabled(commands?.exportMarkdown == nil)
            Button("Карточки для Anki…") { commands?.exportAnki?() }
                .disabled(commands?.exportAnki == nil)
        }
        .disabled(commands == nil)
        Button("Скопировать для чата") { commands?.copyForChat?() }
            .disabled(commands?.copyForChat == nil)
        Divider()
        Button("Изменить лекцию…") { commands?.edit() }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(commands == nil)
        Button("Показать в Finder") { commands?.reveal() }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(commands == nil)
        Divider()
        Button("Отменить работу") { commands?.cancelWork?() }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(commands?.cancelWork == nil)
        Button("Удалить лекцию…") { commands?.delete() }
            .disabled(commands == nil)
    }
}

/// «Файл → Добавить файлы…» (⌘O): фото и PDF в открытый раздел «Источников» лекции.
struct AddFilesCommand: View {
    @FocusedValue(\.lectureCommands) private var commands

    var body: some View {
        Button("Добавить файлы…") { commands?.addFiles() }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(commands == nil)
    }
}

/// «Файл → Конспект в PDF» (⌘P) на месте системного «Напечатать»: печати в приложении нет,
/// а PDF — самый частый экспорт.
struct ExportPDFCommand: View {
    @FocusedValue(\.lectureCommands) private var commands

    var body: some View {
        Button("Конспект в PDF") { commands?.exportPDF?() }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(commands?.exportPDF == nil)
    }
}

/// «Файл → Экспорт предмета в PDF / HTML»: предмет выбранной лекции или открытого в сайдбаре.
struct SubjectExportCommands: View {
    let library: Library
    let export: SubjectExportCenter

    var body: some View {
        let subject = library.currentSubject.flatMap { name in library.subjects.first { $0.name == name } }
        // В названии — какой предмет уйдёт: при «Все лекции» это предмет открытой лекции.
        let name = subject.map { " «\($0.name)»" } ?? ""
        Button("Экспорт предмета\(name) в PDF") { if let subject { export.export(subject, as: .pdf) } }
            .disabled(subject == nil || export.run != nil)
        Button("Экспорт предмета\(name) в HTML") { if let subject { export.export(subject, as: .html) } }
            .disabled(subject == nil || export.run != nil)
    }
}

/// «Правка → Найти лекцию» (⌘F): фокус в поиск списка лекций.
struct FindLectureCommand: View {
    @FocusedValue(\.focusLectureSearch) private var focusSearch

    var body: some View {
        Button("Найти лекцию") { focusSearch?.wrappedValue = true }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(focusSearch == nil)
    }
}

/// «Вид → Крупнее / Мельче / Обычный размер»: масштаб текста для чтения (конспект, вопросы, карточки).
struct ReadingScaleCommands: View {
    @AppStorage(ReadingScale.key) private var scale = 1.0

    var body: some View {
        Button("Крупнее") { scale = ReadingScale.larger(scale) }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(ReadingScale.larger(scale) == scale)
        Button("Мельче") { scale = ReadingScale.smaller(scale) }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(ReadingScale.smaller(scale) == scale)
        Button("Обычный размер") { scale = 1 }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(scale == 1)
    }
}

/// Пункты меню «Вид»: разделы лекции и режим конспекта.
struct LectureViewCommands: View {
    @FocusedValue(\.lectureCommands) private var commands
    @FocusedValue(\.notesEditing) private var notesEditing

    var body: some View {
        ForEach(LectureTab.allCases) { tab in
            Button(tab.title) { commands?.tab.wrappedValue = tab }
                .keyboardShortcut(tab.shortcut, modifiers: .command)
                .disabled(commands == nil)
        }
        Divider()
        Button(notesEditing?.wrappedValue == true ? "Просмотр конспекта" : "Правка конспекта") {
            notesEditing?.wrappedValue.toggle()
        }
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(notesEditing == nil)
        Divider()
    }
}
