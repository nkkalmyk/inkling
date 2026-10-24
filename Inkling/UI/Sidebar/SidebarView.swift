import SwiftUI

/// Первая колонка: «Все лекции» и предметы. Лекции выбранного — в средней колонке (`LectureListView`).
struct SidebarView: View {
    @Environment(Library.self) private var library

    var body: some View {
        List(selection: Binding<LibraryScope?>(get: { library.scope }, set: { if let scope = $0 { library.scope = scope } })) {
            Label("Все лекции", systemImage: "tray.full")
                .badge(library.subjects.reduce(0) { $0 + $1.lectures.count })
                .tag(Optional(LibraryScope.all))
            Section("Предметы") {
                ForEach(library.subjects) { subject in
                    Label(subject.name, systemImage: "book.closed")
                        .badge(subject.lectures.count)
                        .tag(Optional(LibraryScope.subject(subject.name)))
                        .contextMenu { subjectMenu(subject) }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if library.subjects.isEmpty {
                ContentUnavailableView {
                    Label("Нет предметов", systemImage: "books.vertical")
                } description: {
                    Text("Предмет — это папка для лекций одного курса.")
                } actions: {
                    Button("Новый предмет…") { library.sheet = .newSubject }
                }
            }
        }
        // Как «Новая папка» в Заметках: создание раздела — внизу сайдбара, создание лекции — в списке.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button("Новый предмет", systemImage: "plus.circle") { library.sheet = .newSubject }
                .buttonStyle(.borderless)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.s)
                .help("Новый предмет (⇧⌘N)")
        }
        // Переименованный или удалённый предмет больше не выбран.
        .onChange(of: library.subjectNames) {
            if case .subject(let name) = library.scope, !library.subjectNames.contains(name) { library.scope = .all }
        }
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

extension CalendarDate {
    /// «14 октября 2026 г.»
    var formatted: String {
        date().formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "ru_RU")))
    }
}
