import SwiftUI

/// Средняя колонка: лекции выбранного предмета (или все) с поиском по теме и предмету.
/// Поиск идёт по `meta` в памяти: тексты лекций для него не читаются (в iCloud они могут быть выгружены).
struct LectureListView: View {
    @Environment(Library.self) private var library
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var library = library
        let sections = self.sections
        List(selection: $library.selection) {
            ForEach(sections, id: \.subject.id) { section in
                if showsSubjectHeaders {
                    Section(section.subject.name) { rows(section) }
                } else {
                    rows(section)
                }
            }
        }
        .overlay { emptyState(sections) }
        // ⌘⌫ — «Удалить…» выбранной лекции, с тем же подтверждением, что и в контекстном меню.
        .onDeleteCommand { if let id = library.selection { library.requestDeleteLecture(id) } }
        .searchable(text: $query, placement: .toolbar, prompt: "Поиск лекций")
        .searchFocused($searchFocused)
        .focusedSceneValue(\.focusLectureSearch, { searchFocused = true })
        .navigationTitle(title)
        .navigationSubtitle(subtitle(sections))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Новая лекция", systemImage: "square.and.pencil") {
                    library.sheet = .newLecture(subject: library.currentSubject)
                }
                .help("Новая лекция (⌘N)")
                .disabled(library.subjects.isEmpty)
            }
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

    private var sections: [SubjectSection] {
        let subjects: [SubjectRecord] = switch library.scope {
        case .all: library.subjects
        case .subject(let name): library.subjects.filter { $0.name == name }
        }
        let text = query.trimmingCharacters(in: .whitespaces)
        return subjects.compactMap { subject in
            let lectures = subject.lectures
                .filter { text.isEmpty || $0.meta.topic.localizedStandardContains(text)
                    || subject.name.localizedStandardContains(text) }
                .sorted { ($0.meta.date, $0.meta.topic) > ($1.meta.date, $1.meta.topic) }
            let unavailable = text.isEmpty ? subject.unavailable : []
            if lectures.isEmpty && unavailable.isEmpty && showsSubjectHeaders { return nil }
            return SubjectSection(subject: subject, lectures: lectures, unavailable: unavailable)
        }
    }

    @ViewBuilder
    private func rows(_ section: SubjectSection) -> some View {
        ForEach(section.lectures) { lecture in
            LectureRow(lecture: lecture)
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
    @Entry var focusLectureSearch: (() -> Void)?
}

/// Строка лекции: тема, дата и число страниц, справа — тихий статус.
private struct LectureRow: View {
    @Environment(RecognitionCenter.self) private var recognition
    @Environment(AssemblyCenter.self) private var assembly
    @Environment(EnrichmentCenter.self) private var enrichment
    @Environment(StudyCenter.self) private var study
    let lecture: LectureRecord

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
            }
            Spacer(minLength: 0)
            status
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        var parts = [lecture.meta.date.date().formatted(.dateTime.day().month(.abbreviated).locale(UIFormat.locale))]
        let pages = lecture.meta.notes.count + lecture.meta.slides.count
        if pages > 0 { parts.append("страниц: \(pages)") }
        return parts.joined(separator: " · ")
    }

    /// Тихий статус: идёт работа, конфликт iCloud, готовы материалы или конспект.
    @ViewBuilder
    private var status: some View {
        let id = lecture.id
        if recognition.isBusy(id) || assembly.isRunning(id) || enrichment.isRunning(id) || study.isRunning(id) {
            ProgressView().controlSize(.small)
                .accessibilityLabel("Идёт работа")
        } else if lecture.hasConflict {
            StatusSymbol(systemImage: "exclamationmark.icloud", label: "Есть конфликтные копии iCloud")
        } else if lecture.meta.study != nil {
            StatusSymbol(systemImage: "graduationcap", label: "Материалы для самопроверки готовы")
        } else if lecture.meta.konspekt != nil {
            StatusSymbol(systemImage: "doc.text", label: "Конспект собран")
        }
    }
}

private struct UnavailableRow: View {
    let item: UnavailableLecture

    var body: some View {
        HStack(spacing: Spacing.s) {
            switch item.reason {
            case .downloading:
                ProgressView().controlSize(.small)
                Text(item.name).lineLimit(1).foregroundStyle(.secondary)
                    .help("Загружается из iCloud…")
            case .unreadable(let message):
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.statusError)
                Text(item.name).lineLimit(1).foregroundStyle(.secondary)
                    .help("Не удалось прочитать meta.json: \(message)")
            }
        }
    }
}
