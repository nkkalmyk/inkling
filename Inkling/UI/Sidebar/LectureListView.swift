import AppKit
import SwiftUI

/// Средняя колонка: лекции выбранного предмета (или все) с поиском по теме, предмету и тексту конспекта.
/// Сам список файлы не читает (в iCloud они могут быть выгружены): текст ищется в индексе `KonspektSearchCenter`,
/// который читает конспекты в фоне.
struct LectureListView: View {
    @Environment(Library.self) private var library
    @Environment(KonspektSearchCenter.self) private var search
    @Environment(SubjectExportCenter.self) private var subjectExport
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    /// Запрос «Найти лекцию» (⌘F) из строки меню: флаг, а не замыкание — значения `FocusedValues` сравниваются.
    @State private var searchRequested = false

    var body: some View {
        @Bindable var library = library
        let snippets = search.snippets(for: query)
        let sections = sections(snippets)
        List(selection: $library.selection) {
            ForEach(sections, id: \.subject.id) { section in
                if showsSubjectHeaders {
                    Section(section.subject.name) { rows(section, snippets: snippets) }
                } else {
                    rows(section, snippets: snippets)
                }
            }
        }
        .overlay { emptyState(sections) }
        .safeAreaInset(edge: .top, spacing: 0) { exportNotice }
        // ⌫ в списке — «Удалить…» выбранной лекции, с тем же подтверждением, что и в контекстном меню.
        .onDeleteCommand { if let id = library.selection { library.requestDeleteLecture(id) } }
        .searchable(text: $query, placement: .toolbar, prompt: "Поиск лекций")
        .task(id: indexKeys) { search.refresh(allLectures, revisions: library.konspektRevision) }
        .searchFocused($searchFocused)
        .focusedSceneValue(\.focusLectureSearch, $searchRequested)
        .onChange(of: searchRequested) {
            if searchRequested { searchFocused = true; searchRequested = false }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle(sections))
        .toolbar {
            if let run = subjectExport.run {
                ToolbarItem {
                    ActivityIndicator(activities: [Activity(
                        id: "subject-export", title: "Экспорт предмета в \(run.kind.rawValue)",
                        detail: "\(run.subject) · \(run.done) из \(run.total)",
                        fraction: run.total > 0 ? Double(run.done) / Double(run.total) : nil,
                        startedAt: run.startedAt, cancel: { subjectExport.cancel() })])
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Новая лекция", systemImage: "square.and.pencil") {
                    library.sheet = .newLecture(subject: library.currentSubject)
                }
                // Без предметов кнопка тоже работает, как «Файл → Новая лекция…»: лист сам создаёт предмет.
                .help("Новая лекция (⌘T)")
            }
        }
    }

    /// После экспорта предмета — какие лекции не вошли (нет конспекта или он ещё в iCloud).
    @ViewBuilder
    private var exportNotice: some View {
        if let result = subjectExport.result, !result.skipped.isEmpty {
            VStack(spacing: 0) {
                InlineNotice(.info, "Не вошли в файл «\(result.subject)» — нет конспекта: \(result.skipped.joined(separator: ", ")).",
                             systemImage: "doc.badge.ellipsis", dismiss: { subjectExport.result = nil }) {
                    Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([result.url]) }
                }
                .transition(.notice(reduceMotion: reduceMotion))
                Divider()
            }
            .background(.bar)
        }
    }

    // MARK: Содержимое

    private struct SubjectSection {
        var subject: SubjectRecord
        var lectures: [LectureRecord]
        var unavailable: [UnavailableLecture]
    }

    /// В «Все лекции» лекции сгруппированы по предметам, в предмете — просто список.
    private var showsSubjectHeaders: Bool { library.scope == .all }

    private var allLectures: [LectureRecord] { library.subjects.flatMap(\.lectures) }

    /// Индекс поиска обновляется, когда меняется конспект какой-нибудь лекции.
    private var indexKeys: [String?] {
        allLectures.map { KonspektSearchCenter.key($0, revision: library.konspektRevision[$0.id] ?? 0) }
    }

    /// Лекция попадает в поиск по теме, предмету или тексту конспекта (тогда у неё есть фрагмент).
    private func sections(_ snippets: [UUID: KonspektSnippet]) -> [SubjectSection] {
        let subjects: [SubjectRecord] = switch library.scope {
        case .all: library.subjects
        case .subject(let name): library.subjects.filter { $0.name == name }
        }
        let text = query.trimmingCharacters(in: .whitespaces)
        return subjects.compactMap { subject in
            let lectures = subject.lectures
                .filter { text.isEmpty || $0.meta.topic.localizedStandardContains(text)
                    || subject.name.localizedStandardContains(text) || snippets[$0.id] != nil }
                .sorted { ($0.meta.date, $0.meta.topic) > ($1.meta.date, $1.meta.topic) }
            let unavailable = text.isEmpty ? subject.unavailable : []
            if lectures.isEmpty && unavailable.isEmpty && showsSubjectHeaders { return nil }
            return SubjectSection(subject: subject, lectures: lectures, unavailable: unavailable)
        }
    }

    @ViewBuilder
    private func rows(_ section: SubjectSection, snippets: [UUID: KonspektSnippet]) -> some View {
        ForEach(section.lectures) { lecture in
            LectureRow(lecture: lecture, snippet: snippets[lecture.id])
                .tag(lecture.id)
                .contextMenu { lectureMenu(lecture) }
        }
        ForEach(section.unavailable) { item in
            UnavailableRow(item: item)
                .selectionDisabled()
                .contextMenu { Button("Показать в Finder") { library.revealInFinder(item.folder) } }
        }
    }

    @ViewBuilder
    private func emptyState(_ sections: [SubjectSection]) -> some View {
        if sections.allSatisfy({ $0.lectures.isEmpty && $0.unavailable.isEmpty }) {
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView.search(text: query)
            } else if !library.subjects.isEmpty {
                ContentUnavailableView {
                    Label("Нет лекций", systemImage: "doc.text.image")
                } description: {
                    Text("Создайте лекцию и добавьте в неё фото конспекта или слайды.")
                } actions: {
                    Button("Новая лекция…") { library.sheet = .newLecture(subject: library.currentSubject) }
                }
            }
        }
    }

    private var title: String {
        switch library.scope {
        case .all: "Все лекции"
        case .subject(let name): name
        }
    }

    private func subtitle(_ sections: [SubjectSection]) -> String {
        let count = sections.reduce(0) { $0 + $1.lectures.count }
        return count == 0 ? "" : "Лекций: \(count)"
    }

    @ViewBuilder
    private func lectureMenu(_ lecture: LectureRecord) -> some View {
        Button("Изменить…") { library.sheet = .editLecture(lecture.id) }
        Button("Показать в Finder") { library.revealInFinder(lecture.folder) }
        Divider()
        Button("Удалить…", role: .destructive) { library.requestDeleteLecture(lecture.id) }
    }
}

extension FocusedValues {
    /// «Правка → Найти лекцию» (⌘F) ставит фокус в поиск списка лекций.
    @Entry var focusLectureSearch: Binding<Bool>?
}

/// Строка лекции: тема, дата и число страниц, справа — тихий статус. В поиске под ними — фрагмент конспекта.
private struct LectureRow: View {
    @Environment(RecognitionCenter.self) private var recognition
    @Environment(AssemblyCenter.self) private var assembly
    @Environment(StudyCenter.self) private var study
    let lecture: LectureRecord
    var snippet: KonspektSnippet?

    var body: some View {
        HStack(spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(lecture.meta.topic)
                    .font(.headline)
                    .lineLimit(2)
                Text(details)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let snippet {
                    Text(Self.attributed(snippet))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            status
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .combine)
    }

    /// Найденные слова — жирным, а не цветом: выделение должно читаться и без цвета.
    private static func attributed(_ snippet: KonspektSnippet) -> AttributedString {
        snippet.parts.reduce(into: AttributedString()) { result, part in
            var piece = AttributedString(part.text)
            if part.isMatch { piece.inlinePresentationIntent = .stronglyEmphasized }
            result += piece
        }
    }

    private var details: String {
        var parts = [lecture.meta.date.date().formatted(.dateTime.day().month(.abbreviated).locale(UIFormat.locale))]
        let pages = lecture.meta.notes.count + lecture.meta.slides.count
        if pages > 0 { parts.append(UIFormat.count(pages, "страница", "страницы", "страниц")) }
        return parts.joined(separator: " · ")
    }

    /// Тихий статус: идёт работа, конфликт iCloud, готовы материалы или конспект.
    @ViewBuilder
    private var status: some View {
        let id = lecture.id
        if let work = work(id) {
            ProgressView().controlSize(.small)
                .accessibilityLabel(work)
                .help(work)
        } else if let failure = failure(id) {
            // Ошибка видна и из списка: иначе о ней узнаёшь, только открыв лекцию.
            StatusSymbol(systemImage: "exclamationmark.triangle.fill", label: failure, tint: .statusError)
                .help(failure)
        } else if lecture.hasConflict {
            StatusSymbol(systemImage: "exclamationmark.icloud", label: "Есть конфликтные копии iCloud")
        } else if lecture.meta.study != nil {
            StatusSymbol(systemImage: "graduationcap", label: "Материалы для самопроверки готовы")
        } else if lecture.meta.konspekt != nil {
            StatusSymbol(systemImage: "doc.text", label: "Конспект собран")
        }
    }

    /// Что именно идёт по лекции — для подсказки и VoiceOver вместо общего «Идёт работа».
    private func work(_ id: UUID) -> String? {
        if let batch = recognition.batches[id] {
            return "Распознавание: \(batch.done + batch.failed) из \(batch.total)"
        }
        if assembly.isRunning(id) { return "Сборка конспекта" }
        if study.isRunning(id) { return "Подготовка материалов" }
        return nil
    }

    private func failure(_ id: UUID) -> String? {
        if assembly.errors[id] != nil { return "Конспект не собран: ошибка" }
        if study.errors[id] != nil { return "Материалы не подготовлены: ошибка" }
        return nil
    }
}

private struct UnavailableRow: View {
    let item: UnavailableLecture

    private var helpText: String {
        switch item.reason {
        case .downloading: "Загружается из iCloud…"
        case .unreadable(let message): "Не удалось прочитать описание лекции (meta.json): \(message)"
        }
    }

    var body: some View {
        HStack(spacing: Spacing.s) {
            switch item.reason {
            case .downloading:
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Загружается из iCloud")
                Text(item.name).lineLimit(1).foregroundStyle(.secondary)
            case .unreadable:
                StatusSymbol(systemImage: "exclamationmark.triangle", label: "Не удалось прочитать лекцию", tint: .statusError)
                Text(item.name).lineLimit(1).foregroundStyle(.secondary)
            }
        }
        // Причина — на всю строку, а не только на текст; служебное имя файла — в подробностях.
        .help(helpText)
    }
}
