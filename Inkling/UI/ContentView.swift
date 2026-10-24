import SwiftUI

struct ContentView: View {
    @Environment(Library.self) private var library
    @AppStorage(ReadingScale.key) private var readingScale = 1.0
    @State private var dropTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var library = library
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 320)
        } content: {
            LectureListView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 400)
        } detail: {
            if let lecture = library.selectedLecture {
                LectureView(lecture: lecture)
                    .id(lecture.id)
            } else {
                ContentUnavailableView {
                    Label("Выберите лекцию", systemImage: "book.closed")
                } description: {
                    Text("Или создайте новую: фото конспекта и слайды добавляются внутри лекции.")
                } actions: {
                    Button("Новая лекция…") { library.sheet = .newLecture(subject: library.currentSubject) }
                }
            }
        }
        .environment(\.readingScale, readingScale)
        // Фото и PDF можно бросить или вставить в любое место окна; «Источники» принимают их в свой раздел сами.
        .onDrop(of: ImportStaging.acceptedTypes, isTargeted: $dropTargeted) { providers in
            library.importIntoWindow(providers)
            return true
        }
        .onPasteCommand(of: ImportStaging.acceptedTypes) { library.importIntoWindow($0) }
        .overlay { if dropTargeted { dropHint.transition(.opacity) } }
        .motion(.snappy, value: dropTargeted)
        .onChange(of: library.sheet == nil) { if library.sheet == nil { library.discardPendingImport() } }
        // Пункт меню «Крупнее» ловит только ⌘⇧= (символ «+»); ⌘= без Shift, как в Safari, — этой кнопкой.
        .background {
            Button("Крупнее") { readingScale = ReadingScale.larger(readingScale) }
                .keyboardShortcut("=", modifiers: .command)
                .hidden()
                .accessibilityHidden(true)
        }
        .sheet(item: $library.sheet) { sheet in
            switch sheet {
            case .newLecture(let subject):
                LectureEditorSheet(mode: .create(subject: subject))
            case .editLecture(let id):
                LectureEditorSheet(mode: .edit(id))
            case .newSubject:
                SubjectNameSheet(mode: .create)
            case .renameSubject(let name):
                SubjectNameSheet(mode: .rename(name))
            }
        }
        .confirmationDialog(deletionTitle, isPresented: deletionBinding, titleVisibility: .visible,
                            presenting: library.pendingDeletion) { deletion in
            Button("Переместить в корзину", role: .destructive) { library.confirmDeletion(deletion) }
            Button("Отмена", role: .cancel) {}
        } message: { deletion in
            Text(deletionMessage(deletion))
        }
        .confirmationDialog(pdfQuestionTitle, isPresented: pdfQuestionBinding, titleVisibility: .visible,
                            presenting: library.pdfQuestion) { question in
            Button("Добавить в «\(question.guess.title)»") { library.answerPDFQuestion(question, section: question.guess) }
            Button("Добавить в «\(question.requested.title)»") { library.answerPDFQuestion(question, section: question.requested) }
            Button("Отмена", role: .cancel) { library.answerPDFQuestion(question, section: nil) }
        } message: { question in
            Text(question.guess == .slides
                 ? "В PDF есть текстовый слой, обычно так выглядят слайды преподавателя."
                 : "В PDF нет текстового слоя, обычно так выглядит скан тетради.")
        }
        .alert("Ошибка", isPresented: errorBinding) {
            Button("OK") { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "")
        }
    }

    /// Куда попадут брошенные файлы: рамка по краю окна и подпись на стекле.
    private var dropHint: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle.ds(Radius.card)
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .padding(Spacing.s)
            Label(library.selectedLecture.map { "Добавить в «\($0.meta.topic)»" } ?? "Добавить в новую лекцию",
                  systemImage: "photo.badge.plus")
                .font(.headline)
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.s)
                .background(.regularMaterial, in: .capsule)
                .padding(.bottom, Spacing.xxl)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var deletionBinding: Binding<Bool> {
        Binding(get: { library.pendingDeletion != nil }, set: { if !$0 { library.pendingDeletion = nil } })
    }

    private var pdfQuestionBinding: Binding<Bool> {
        Binding(get: { library.pdfQuestion != nil }, set: { shown in
            if !shown, let question = library.pdfQuestion { library.answerPDFQuestion(question, section: nil) }
        })
    }

    private var pdfQuestionTitle: String {
        library.pdfQuestion?.guess == .slides ? "Похоже, это слайды" : "Похоже, это скан тетради"
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })
    }

    private var deletionTitle: String {
        switch library.pendingDeletion {
        case .lecture(_, let title): "Удалить лекцию «\(title)»?"
        case .subject(let name, _): "Удалить предмет «\(name)»?"
        case nil: ""
        }
    }

    private func deletionMessage(_ deletion: Library.Deletion) -> String {
        switch deletion {
        case .lecture:
            return "Папка лекции со всеми фото, текстами и материалами уйдёт в корзину."
        case .subject(_, let count):
            return count == 0
                ? "Папка предмета уйдёт в корзину."
                : "Папка предмета и все его лекции (\(count)) уйдут в корзину."
        }
    }
}
