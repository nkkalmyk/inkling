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
    var reviewCards = false
    /// «Файл → Добавить файлы…»: панель выбора открывает «Источники».
    var addFiles = false
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
        case .recognize(let pages): "Распознать \(UIFormat.count(pages.count, "страницу", "страницы", "страниц"))"
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
        // Сводки из кэша: тексты читаются в фоне, пока их нет — следующий шаг не предлагается.
        guard let readiness = assembly.knownReadiness(lecture) else { return nil }
        if readiness.plan != nil, lecture.meta.konspekt == nil || readiness.isStale {
            return .assemble(rebuild: lecture.meta.konspekt != nil)
        }
        if lecture.meta.konspekt != nil, lecture.meta.study == nil || study.knownStale(lecture) {
            return .prepareStudy(rebuild: lecture.meta.study != nil)
        }
        return nil
    }
}

// MARK: Активность

/// Что сейчас идёт по лекции: импорт, распознавание, сборка, подготовка материалов, исправление формул, экспорт.
struct LectureActivityIndicator: View {
    @Environment(Library.self) private var library
    @Environment(RecognitionCenter.self) private var recognition
    @Environment(AssemblyCenter.self) private var assembly
    @Environment(StudyCenter.self) private var study
    @Environment(KonspektCheckCenter.self) private var checker
    let lecture: LectureRecord
    var exportingPDFSince: Date?
    var exportingHTMLSince: Date?

    var body: some View {
        ActivityIndicator(activities: activities)
    }

    private var activities: [Activity] {
        let id = lecture.id
        var result: [Activity] = []
        if let progress = library.importProgress, progress.lectureID == id {
            result.append(Activity(id: "import", title: "Импорт",
                                   detail: progress.total > 0 ? "\(progress.done) из \(progress.total)" : "Подготовка",
                                   fraction: progress.total > 0 ? Double(progress.done) / Double(progress.total) : nil,
                                   cancel: { library.cancelImport(lectureID: id) }))
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
        if checker.isFixing(id) {
            result.append(Activity(id: "fix", title: "Исправление формул", cancel: { checker.cancelFix(id) }))
        }
        if let exportingPDFSince {
            result.append(Activity(id: "pdf", title: "Экспорт в PDF", startedAt: exportingPDFSince))
        }
        if let exportingHTMLSince {
            result.append(Activity(id: "html", title: "Экспорт в HTML", startedAt: exportingHTMLSince))
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

/// Какая кнопка тулбара лекции яркая: следующий шаг или «PDF» (SPEC, раздел 13). Яркая всегда одна.
enum LectureProminentButton: Equatable {
    case primary, pdf, none

    /// Распознать и собрать важнее экспорта: иначе в PDF уйдёт неполный или устаревший конспект.
    /// «Подготовить материалы» уступает «PDF» вне самопроверки. Пока фоновая сводка по текстам не готова,
    /// «PDF» не выделяется: через мгновение главной может стать «Пересобрать», и кнопки мигнули бы.
    static func choose(primary: LecturePrimaryAction?, pdfAvailable: Bool, summaryKnown: Bool,
                       tab: LectureTab) -> Self {
        switch primary {
        case .recognize, .assemble: .primary
        case .prepareStudy: pdfAvailable && !tab.isStudy ? .pdf : .primary
        case nil: pdfAvailable && summaryKnown ? .pdf : .none
        }
    }
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

// MARK: Вкладки без пересборки

/// Открытые вкладки лекции: у каждой свой `NSHostingView`, переключение — прозрачность хоста.
/// Если держать вкладки в одном SwiftUI-дереве и прятать прозрачностью, SwiftUI при каждом переключении
/// вынимает AppKit-виды скрытой вкладки из окна и вставляет обратно (списки, веб-вью, редактор),
/// пересобирает список отрисовки и цепочку клавиатурного фокуса — это и был рывок анимации.
struct KeptAliveTabs<Content: View>: NSViewRepresentable {
    let tabs: [LectureTab]
    let active: LectureTab
    /// Данные, от которых зависит содержимое вкладок (лекция). Пока они те же, переключение не трогает
    /// содержимое вкладок вовсе: меняется только видимость и флаг активности.
    let revision: LectureRecord
    @ViewBuilder let content: (LectureTab) -> Content

    final class Coordinator {
        var hosts: [LectureTab: NSHostingView<ActivityRoot>] = [:]
        var activities: [LectureTab: TabActivity] = [:]
        var key: EnvironmentKey?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> Container {
        let view = Container()
        view.autoresizesSubviews = true
        return view
    }

    /// Щелчки получает только видимая вкладка: прозрачные неактивные лежат рядом и не должны их ловить.
    final class Container: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            // point — в координатах суперпредставления; подвидам нужен в своих.
            let local = convert(point, from: superview)
            for host in subviews.reversed() where !host.isHidden && host.alphaValue > 0 {
                if let hit = host.hitTest(local) { return hit }
            }
            return nil
        }
    }

    func updateNSView(_ view: Container, context: Context) {
        let coordinator = context.coordinator
        let environment = context.environment
        // Окружение копируется в хосты целиком; пересобираем их при смене лекции и тех значений окружения,
        // что меняются на ходу (тема, контраст, «Уменьшить движение», размер текста).
        let key = EnvironmentKey(revision: revision, colorScheme: environment.colorScheme,
                                 contrast: environment.colorSchemeContrast,
                                 reduceMotion: environment.accessibilityReduceMotion,
                                 reduceTransparency: environment.accessibilityReduceTransparency,
                                 dynamicTypeSize: environment.dynamicTypeSize,
                                 readingScale: environment.readingScale)
        let revisionChanged = coordinator.key != key
        coordinator.key = key
        for tab in tabs {
            let isActive = tab == active
            let activity = coordinator.activities[tab] ?? TabActivity(isActive: isActive)
            coordinator.activities[tab] = activity
            if activity.isActive != isActive { activity.isActive = isActive }
            let root = { ActivityRoot(activity: activity, content: AnyView(content(tab).environment(\.self, environment))) }
            if let host = coordinator.hosts[tab] {
                if revisionChanged { host.rootView = root() }
            } else {
                let host = NSHostingView(rootView: root())
                host.sizingOptions = []
                host.frame = view.bounds
                host.autoresizingMask = [.width, .height]
                view.addSubview(host)
                coordinator.hosts[tab] = host
            }
            // Неактивная вкладка полностью прозрачна, но не скрыта: скрытый хост при показе заново
            // собирает и отрисовывает AppKit-виды, а прозрачный уже готов. Щелчки, VoiceOver и фокус
            // ей не достаются (Container.hitTest, ActivityRoot, isActiveTab).
            coordinator.hosts[tab]?.alphaValue = isActive ? 1 : 0
        }
        // Фокус не остаётся в ставшей прозрачной вкладке: иначе набор с клавиатуры уходил бы в невидимый редактор.
        if let window = view.window, let responder = window.firstResponder as? NSView,
           let owner = coordinator.hosts.first(where: { responder.isDescendant(of: $0.value) })?.key, owner != active {
            window.makeFirstResponder(coordinator.hosts[active])
        }
    }

    struct EnvironmentKey: Equatable {
        var revision: LectureRecord
        var colorScheme: ColorScheme
        var contrast: ColorSchemeContrast
        var reduceMotion: Bool
        var reduceTransparency: Bool
        var dynamicTypeSize: DynamicTypeSize
        var readingScale: Double
    }
}

/// Видна ли вкладка. Объект, а не значение в rootView: при переключении обновляются только виды,
/// которые читают `\.isActiveTab`, а не всё дерево вкладки.
@Observable
final class TabActivity {
    var isActive: Bool
    init(isActive: Bool) { self.isActive = isActive }
}

struct ActivityRoot: View {
    let activity: TabActivity
    let content: AnyView

    var body: some View {
        // Хост-вид центрирует корень по его собственному размеру: вкладка должна занимать всю область,
        // иначе фон зоны и пустые состояния собираются комком посередине.
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.isActiveTab, activity.isActive)
            .accessibilityHidden(!activity.isActive)
    }
}
