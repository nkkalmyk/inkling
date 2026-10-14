import SwiftUI

struct SidebarView: View {
    @Environment(Library.self) private var library
    @State private var collapsed: Set<String> = []

    var body: some View {
        @Bindable var library = library
        List(selection: $library.selection) {
            ForEach(library.subjects) { subject in
                Section(isExpanded: expansion(for: subject.name)) {
                    ForEach(subject.lectures) { lecture in
                        LectureRow(lecture: lecture)
                            .tag(lecture.id)
                            .contextMenu { lectureMenu(lecture) }
                    }
                    ForEach(subject.unavailable) { item in
                        UnavailableRow(item: item)
                            .selectionDisabled()
                            .contextMenu {
                                Button("Показать в Finder") { library.revealInFinder(item.folder) }
                            }
                    }
                    if subject.lectures.isEmpty && subject.unavailable.isEmpty {
                        Text("Нет лекций")
                            .foregroundStyle(.tertiary)
                            .selectionDisabled()
                    }
                } header: {
                    Text(subject.name)
                        .contextMenu { subjectMenu(subject) }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if library.subjects.isEmpty {
                ContentUnavailableView {
                    Label("Нет предметов", systemImage: "books.vertical")
                } actions: {
                    Button("Новый предмет…") { library.sheet = .newSubject }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Новая лекция…") { library.sheet = .newLecture(subject: library.selectedLecture?.meta.subject) }
                    Button("Новый предмет…") { library.sheet = .newSubject }
                } label: {
                    Label("Добавить", systemImage: "plus")
                }
                .help("Новая лекция или предмет")
            }
        }
    }

    private func expansion(for name: String) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(name) },
                set: { expanded in if expanded { collapsed.remove(name) } else { collapsed.insert(name) } })
    }

    @ViewBuilder
    private func lectureMenu(_ lecture: LectureRecord) -> some View {
        Button("Изменить…") { library.sheet = .editLecture(lecture.id) }
        Button("Показать в Finder") { library.revealInFinder(lecture.folder) }
        Divider()
        Button("Удалить…", role: .destructive) { library.requestDeleteLecture(lecture.id) }
    }

    @ViewBuilder
    private func subjectMenu(_ subject: SubjectRecord) -> some View {
        Button("Новая лекция…") { library.sheet = .newLecture(subject: subject.name) }
        Button("Переименовать…") { library.sheet = .renameSubject(subject.name) }
        Button("Показать в Finder") { library.revealInFinder(subject.folder) }
        Divider()
        Button("Удалить…", role: .destructive) { library.requestDeleteSubject(subject.name) }
    }
}

private struct LectureRow: View {
    let lecture: LectureRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(lecture.meta.topic)
                    .lineLimit(1)
                if lecture.hasConflict {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .help("Есть конфликтные копии iCloud")
                }
            }
            Text(lecture.meta.date.formatted)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct UnavailableRow: View {
    let item: UnavailableLecture

    var body: some View {
        HStack(spacing: 6) {
            switch item.reason {
            case .downloading:
                ProgressView().controlSize(.small)
                Text(item.name).lineLimit(1).foregroundStyle(.secondary)
                    .help("Загружается из iCloud…")
            case .unreadable(let message):
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(item.name).lineLimit(1).foregroundStyle(.secondary)
                    .help("Не удалось прочитать meta.json: \(message)")
            }
        }
    }
}

extension CalendarDate {
    /// «14 октября 2026 г.»
    var formatted: String {
        date().formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "ru_RU")))
    }
}
