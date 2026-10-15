import SwiftUI

/// Разделы лекции. Две зоны: «Материалы» (строгая) и «Самопроверка» (тёплая).
enum LectureTab: String, CaseIterable, Identifiable {
    case sources, notes, questions, quiz, flashcards

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sources: "Источники"
        case .notes: "Конспект"
        case .questions: "Вопросы"
        case .quiz: "Тест"
        case .flashcards: "Карточки"
        }
    }

    var isStudy: Bool { self == .questions || self == .quiz || self == .flashcards }

    /// ⌘1–⌘5 в меню «Вид».
    var shortcut: KeyEquivalent {
        KeyEquivalent(Character(String((Self.allCases.firstIndex(of: self) ?? 0) + 1)))
    }

    static let studyTabs: [LectureTab] = [.questions, .quiz, .flashcards]
}

/// Пункт переключателя в тулбаре: три сегмента, самопроверка — одним.
enum LectureZoneItem: String, CaseIterable, Identifiable {
    case sources, notes, study

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sources: "Источники"
        case .notes: "Конспект"
        case .study: "Самопроверка"
        }
    }

    init(_ tab: LectureTab) {
        self = switch tab {
        case .sources: .sources
        case .notes: .notes
        case .questions, .quiz, .flashcards: .study
        }
    }
}

// MARK: Запросы от тулбара и меню к экранам

/// Главная кнопка и меню просят экран запустить действие с его подтверждениями
/// («Конспект правился вручную…»). Экран забирает флаг (сбрасывает его) и выполняет запрос —
/// и когда флаг поднят при уже открытом экране, и когда экран только появился после переключения вкладки.
struct LectureRequests: Equatable {
    var assemble = false
    var prepareStudy = false
}

extension EnvironmentValues {
    @Entry var lectureRequests: Binding<LectureRequests> = .constant(LectureRequests())
    /// Вкладка лекции видна. Открытые вкладки остаются в памяти скрытыми (переключение без пересоздания
    /// веб-вью), и скрытая не должна забирать фокус, клавиши, вставку и запросы тулбара.
    @Entry var isActiveTab = true
}

// MARK: Главное действие

/// Следующий шаг по лекции: распознать → собрать конспект → подготовить материалы.
enum LecturePrimaryAction: Equatable {
    case recognize(pages: [String])
    case assemble(rebuild: Bool)
    case prepareStudy(rebuild: Bool)

    var title: String {
        switch self {
        case .recognize(let pages): "Распознать (\(pages.count))"
        case .assemble(let rebuild): rebuild ? "Пересобрать конспект" : "Собрать конспект"
        case .prepareStudy(let rebuild): rebuild ? "Подготовить заново" : "Подготовить материалы"
        }
    }

    var systemImage: String {
        switch self {
        case .recognize: "text.viewfinder"
        case .assemble: "doc.text"
        case .prepareStudy: "graduationcap"
        }
    }

    /// Пока по лекции что-то идёт, следующий шаг не предлагается.
    @MainActor
    static func next(for lecture: LectureRecord, recognition: RecognitionCenter, assembly: AssemblyCenter,
                     study: StudyCenter) -> LecturePrimaryAction? {
        let id = lecture.id
        guard !recognition.isBusy(id), !assembly.isRunning(id), !study.isRunning(id) else { return nil }
        let pending = recognition.pendingPages(in: lecture)
        if !pending.isEmpty { return .recognize(pages: pending) }
        let readiness = assembly.readiness(lecture)
        if readiness.plan != nil, lecture.meta.konspekt == nil || readiness.isStale {
            return .assemble(rebuild: lecture.meta.konspekt != nil)
        }
        if lecture.meta.konspekt != nil, lecture.meta.study == nil || study.isStale(lecture) {
            return .prepareStudy(rebuild: lecture.meta.study != nil)
        }
        return nil
    }
}

// MARK: Активность

/// Что сейчас идёт по лекции: импорт, распознавание, сборка, подготовка материалов, экспорт PDF.
struct LectureActivityIndicator: View {
    @Environment(Library.self) private var library
    @Environment(RecognitionCenter.self) private var recognition
    @Environment(AssemblyCenter.self) private var assembly
    @Environment(StudyCenter.self) private var study
    let lecture: LectureRecord
    var exportingPDFSince: Date?

    var body: some View {
        ActivityIndicator(activities: activities)
    }

    private var activities: [Activity] {
        let id = lecture.id
        var result: [Activity] = []
        if let progress = library.importProgress, progress.lectureID == id {
            result.append(Activity(id: "import", title: "Импорт",
                                   detail: progress.total > 0 ? "\(progress.done) из \(progress.total)" : "Подготовка",
                                   fraction: progress.total > 0 ? Double(progress.done) / Double(progress.total) : nil))
        }
        if let batch = recognition.batches[id] {
            let processed = batch.done + batch.failed
            var detail = ["\(processed) из \(batch.total)"]
            if batch.failed > 0 { detail.append("ошибок: \(batch.failed)") }
            if let engine = batch.engine { detail.append(engine.title) }
            result.append(Activity(id: "recognition", title: "Распознавание", detail: detail.joined(separator: " · "),
                                   fraction: Double(processed) / Double(max(batch.total, 1)),
                                   startedAt: batch.startedAt, note: batch.note,
                                   cancel: { recognition.cancel(lectureID: id) }))
        }
        if let run = assembly.runs[id] {
            var detail: [String] = []
            if run.totalCalls > 1, !run.merging { detail.append("частей \(run.finishedCalls) из \(run.totalCalls - 1)") }
            if let engine = run.engine { detail.append(engine.title) }
            result.append(Activity(id: "assembly", title: run.merging ? "Склейка частей" : "Сборка конспекта",
                                   detail: detail.isEmpty ? nil : detail.joined(separator: " · "),
                                   fraction: run.totalCalls > 1 ? Double(run.finishedCalls) / Double(run.totalCalls) : nil,
                                   startedAt: run.startedAt, note: run.note, cancel: { assembly.cancel(id) }))
        }
        if let run = study.runs[id] {
            result.append(Activity(id: "study", title: "Подготовка материалов", detail: run.engine?.title,
                                   startedAt: run.startedAt, note: run.note, cancel: { study.cancel(id) }))
        }
        if let exportingPDFSince {
            result.append(Activity(id: "pdf", title: "Экспорт в PDF", startedAt: exportingPDFSince))
        }
        return result
    }
}

// MARK: Команды строки меню

/// Действия лекции для строки меню. `nil` — пункт недоступен.
struct LectureCommands {
    var tab: Binding<LectureTab>
    var primary: LecturePrimaryAction?
    var perform: (LecturePrimaryAction) -> Void
    var exportMarkdown: (() -> Void)?
    var exportPDF: (() -> Void)?
    var exportAnki: (() -> Void)?
    var edit: () -> Void
    var reveal: () -> Void
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
        Divider()
        Menu("Экспорт") {
            Button("Конспект в Markdown…") { commands?.exportMarkdown?() }
                .disabled(commands?.exportMarkdown == nil)
            Button("Конспект в PDF…") { commands?.exportPDF?() }
                .disabled(commands?.exportPDF == nil)
            Button("Карточки для Anki…") { commands?.exportAnki?() }
                .disabled(commands?.exportAnki == nil)
        }
        .disabled(commands == nil)
        Divider()
        Button("Изменить лекцию…") { commands?.edit() }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(commands == nil)
        Button("Показать в Finder") { commands?.reveal() }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(commands == nil)
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
