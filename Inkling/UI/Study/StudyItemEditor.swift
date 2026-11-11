import SwiftUI

// MARK: Правка

enum EditTarget: Identifiable, Equatable {
    case question(String), quiz(String), flashcard(String)

    var id: String {
        switch self {
        case .question(let id), .quiz(let id), .flashcard(let id): id
        }
    }
}

/// Ручная правка вопроса, вопроса теста или карточки (SPEC, раздел 7).
struct StudyItemEditor: View {
    let target: EditTarget
    let materials: StudyMaterials
    let save: (StudyMaterials) -> Void
    @State private var draft: StudyMaterials

    init(target: EditTarget, materials: StudyMaterials, save: @escaping (StudyMaterials) -> Void) {
        self.target = target
        self.materials = materials
        self.save = save
        _draft = State(initialValue: materials)
    }

    var body: some View {
        FormSheet(title: title, subtitle: "Можно использовать Markdown и формулы: $…$, $$…$$, \\ce{…}.",
                  width: SheetWidth.wide, confirmTitle: "Сохранить", canConfirm: draft.problems().isEmpty,
                  fitsContent: false,
                  destructive: (title: "Удалить", action: delete),
                  confirm: {
                      save(draft)
                      return true
                  }) {
            fields
            if !draft.problems().isEmpty {
                Text(draft.problems().joined(separator: " ")).font(.caption).foregroundStyle(Color.statusError)
            }
        }
        .frame(height: 560)
    }

    private var title: String {
        switch target {
        case .question: "Вопрос"
        case .quiz: "Вопрос теста"
        case .flashcard: "Карточка"
        }
    }

    @ViewBuilder
    private var fields: some View {
        switch target {
        case .question(let id):
            if let i = draft.questions.firstIndex(where: { $0.id == id }) {
                Picker("Тип", selection: $draft.questions[i].type) {
                    ForEach(StudyMaterials.QuestionType.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Сложность", selection: $draft.questions[i].difficulty) {
                    ForEach(StudyMaterials.Difficulty.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                TextField("Вопрос", text: $draft.questions[i].question, axis: .vertical).lineLimit(2...6)
                TextField("Ответ", text: $draft.questions[i].answer, axis: .vertical).lineLimit(2...6)
                TextField("Решение", text: Binding(get: { draft.questions[i].solution ?? "" },
                                                   set: { draft.questions[i].solution = $0.isEmpty ? nil : $0 }),
                          axis: .vertical).lineLimit(2...8)
            }
        case .quiz(let id):
            if let i = draft.quiz.firstIndex(where: { $0.id == id }) {
                TextField("Вопрос", text: $draft.quiz[i].question, axis: .vertical).lineLimit(2...5)
                ForEach(draft.quiz[i].options.indices, id: \.self) { k in
                    TextField("Вариант \(k + 1)", text: $draft.quiz[i].options[k])
                }
                Picker("Верный вариант", selection: $draft.quiz[i].correctIndex) {
                    ForEach(draft.quiz[i].options.indices, id: \.self) { Text("\($0 + 1)").tag($0) }
                }
                .pickerStyle(.segmented)
                TextField("Объяснение", text: $draft.quiz[i].explanation, axis: .vertical).lineLimit(2...6)
            }
        case .flashcard(let id):
            if let i = draft.flashcards.firstIndex(where: { $0.id == id }) {
                TextField("Лицевая сторона", text: $draft.flashcards[i].front, axis: .vertical).lineLimit(2...6)
                TextField("Оборот", text: $draft.flashcards[i].back, axis: .vertical).lineLimit(2...8)
            }
        }
    }

    private func delete() {
        switch target {
        case .question(let id): draft.questions.removeAll { $0.id == id }
        case .quiz(let id): draft.quiz.removeAll { $0.id == id }
        case .flashcard(let id): draft.flashcards.removeAll { $0.id == id }
        }
        save(draft)
    }
}
