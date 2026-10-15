import SwiftUI

/// Общая обвязка вкладок «Вопросы», «Тест», «Карточки»: подготовка материалов, «Устарело», ошибки.
struct StudyContainer<Content: View>: View {
    @Environment(StudyCenter.self) private var study
    let lecture: LectureRecord
    let showNotes: () -> Void
    @ViewBuilder let content: (StudyMaterials, StudyProgress) -> Content

    @State private var confirmRegenerate = false
    @Environment(\.lectureRequests) private var requests
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let store = study.store(lecture)
        let _ = study.revision(lecture.id)
        let materials = store.readStudy()
        VStack(spacing: 0) {
            if !study.isRunning(lecture.id) {
                if let error = study.errors[lecture.id] {
                    InlineNotice(.error, "Материалы не подготовлены. \(error.userMessage)",
                                 systemImage: "exclamationmark.octagon.fill", details: error.details,
                                 dismiss: { study.errors[lecture.id] = nil }) {
                        if hasKonspekt { Button("Повторить") { study.generate(lecture.id) } }
                    }
                    .transition(.notice(reduceMotion: reduceMotion))
                    Divider()
                } else if materials != nil, study.isStale(lecture) {
                    InlineNotice(.info, "Устарело: конспект изменился после подготовки материалов.",
                                 systemImage: "clock.arrow.circlepath") {
                        Button("Подготовить заново", action: regenerate)
                    }
                    .transition(.notice(reduceMotion: reduceMotion))
                    Divider()
                }
            }
            if let materials {
                content(materials, store.readProgress())
            } else {
                emptyState
            }
        }
        .motion(.standard, value: study.errors[lecture.id] == nil)
        .task(id: requests.wrappedValue.prepareStudy) {
            guard requests.wrappedValue.prepareStudy else { return }
            requests.wrappedValue.prepareStudy = false
            if materials == nil { study.generate(lecture.id) } else { regenerate() }
        }
        .confirmationDialog("Подготовить материалы заново?", isPresented: $confirmRegenerate) {
            Button("Подготовить") { study.generate(lecture.id) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Прогресс самопроверки начнётся заново. Старые материалы и прогресс сохранятся в истории"
                 + (lecture.meta.study?.manuallyEdited == true ? ", включая ваши правки." : "."))
        }
    }

    private var hasKonspekt: Bool { KonspektStore(folder: lecture.folder).read()?.isEmpty == false }

    func regenerate() {
        let progress = study.store(lecture).readProgress()
        if lecture.meta.study?.manuallyEdited == true || !progress.isEmpty { confirmRegenerate = true }
        else { study.generate(lecture.id) }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Учебных материалов пока нет", systemImage: "graduationcap")
        } description: {
            Text(hasKonspekt
                 ? "Вопросы, тест и карточки готовятся по конспекту. Проверьте конспект перед запуском, чтобы ошибки распознавания не попали в карточки."
                 : "Сначала соберите конспект на вкладке «Конспект».")
        } actions: {
            if hasKonspekt {
                Button("Подготовить материалы") { study.generate(lecture.id) }
                    .prominentAction()
                    .disabled(study.isRunning(lecture.id))
            } else {
                Button("Перейти к конспекту", action: showNotes)
            }
        }
    }

}

/// Строка с источником материалов и кнопкой «Подготовить заново».
private struct StudyToolbar: View {
    @Environment(StudyCenter.self) private var study
    let lecture: LectureRecord
    var trailing: AnyView = AnyView(EmptyView())
    @State private var confirm = false

    var body: some View {
        HStack(spacing: 10) {
            if let info = lecture.meta.study {
                Text([info.model, info.updatedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute()
                    .locale(Locale(identifier: "ru_RU"))), info.manuallyEdited ? "правлено вручную" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                ReviewBadge(engine: info.engine, manuallyEdited: info.manuallyEdited)
            }
            Spacer()
            trailing
            Button("Подготовить заново") {
                let progress = study.store(lecture).readProgress()
                if lecture.meta.study?.manuallyEdited == true || !progress.isEmpty { confirm = true }
                else { study.generate(lecture.id) }
            }
            .disabled(study.isRunning(lecture.id))
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .confirmationDialog("Подготовить материалы заново?", isPresented: $confirm) {
            Button("Подготовить") { study.generate(lecture.id) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Прогресс самопроверки начнётся заново. Старые материалы и прогресс сохранятся в истории.")
        }
    }
}

/// Флажок «ошибка в вопросе».
private struct FlagButton: View {
    @Environment(StudyCenter.self) private var study
    let lectureID: UUID
    let itemID: String
    let flagged: Bool

    var body: some View {
        Button {
            study.updateProgress(lectureID) { progress in
                if flagged { progress.flagged.remove(itemID) } else { progress.flagged.insert(itemID) }
            }
        } label: {
            Image(systemName: flagged ? "flag.fill" : "flag")
                .foregroundStyle(flagged ? .red : .secondary)
        }
        .buttonStyle(.borderless)
        .help(flagged ? "Снять пометку «ошибка в вопросе»" : "Ошибка в вопросе: не учитывать и не показывать в самопроверке")
    }
}

// MARK: Вопросы

struct QuestionsView: View {
    @Environment(StudyCenter.self) private var study
    let lecture: LectureRecord
    let showNotes: () -> Void

    @State private var typeFilter: StudyMaterials.QuestionType?
    @State private var difficultyFilter: StudyMaterials.Difficulty?
    @State private var revealed: Set<String> = []
    @State private var editing: EditTarget?

    var body: some View {
        StudyContainer(lecture: lecture, showNotes: showNotes) { materials, progress in
            VStack(spacing: 0) {
                StudyToolbar(lecture: lecture, trailing: AnyView(filters))
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        summary(materials)
                        let items = materials.questions.filter {
                            (typeFilter == nil || $0.type == typeFilter) && (difficultyFilter == nil || $0.difficulty == difficultyFilter)
                        }
                        Text("Вопросы (\(items.count))").font(.title3.weight(.semibold)).padding(.top, 6)
                        ForEach(items) { question in
                            questionCard(question, flagged: progress.flagged.contains(question.id))
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                }
            }
            .sheet(item: $editing) { target in
                StudyItemEditor(target: target, materials: materials) { updated in
                    study.saveEdited(updated, lectureID: lecture.id)
                }
            }
        }
    }

    private var filters: some View {
        HStack(spacing: 8) {
            Picker("Тип", selection: $typeFilter) {
                Text("Все типы").tag(StudyMaterials.QuestionType?.none)
                ForEach(StudyMaterials.QuestionType.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
            }
            .fixedSize()
            Picker("Сложность", selection: $difficultyFilter) {
                Text("Любая сложность").tag(StudyMaterials.Difficulty?.none)
                ForEach(StudyMaterials.Difficulty.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
            }
            .fixedSize()
        }
        .labelsHidden()
    }

    @ViewBuilder
    private func summary(_ materials: StudyMaterials) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(materials.summary.enumerated()), id: \.offset) { _, point in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        MathText(markdown: point)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Кратко").font(.title3.weight(.semibold))
        }
        if !materials.terms.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(materials.terms) { term in
                        VStack(alignment: .leading, spacing: 2) {
                            MathText(markdown: "**\(term.term)**")
                            MathText(markdown: term.definition).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("Термины (\(materials.terms.count))").font(.title3.weight(.semibold))
            }
        }
    }

    private func questionCard(_ q: StudyMaterials.Question, flagged: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Tag(text: q.type.title)
                Tag(text: q.difficulty.title)
                if flagged { Tag(text: "Ошибка в вопросе", color: .red) }
                Spacer()
                Button { editing = .question(q.id) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless).help("Изменить вопрос")
                FlagButton(lectureID: lecture.id, itemID: q.id, flagged: flagged)
            }
            MathText(markdown: q.question)
            if revealed.contains(q.id) {
                Divider()
                Text("Ответ").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                MathText(markdown: q.answer)
                if let solution = q.solution, !solution.isEmpty {
                    Text("Решение").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    MathText(markdown: solution)
                }
            }
            Button(revealed.contains(q.id) ? "Скрыть ответ" : "Показать ответ") {
                if revealed.contains(q.id) { revealed.remove(q.id) } else { revealed.insert(q.id) }
            }
            .buttonStyle(.link)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
        .opacity(flagged ? 0.55 : 1)
    }
}

private struct Tag: View {
    let text: String
    var color: Color = .accentColor

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: Тест

struct QuizView: View {
    @Environment(StudyCenter.self) private var study
    let lecture: LectureRecord
    let showNotes: () -> Void

    @State private var session: QuizSession?
    @State private var editing: EditTarget?
    @FocusState private var focused: Bool

    var body: some View {
        StudyContainer(lecture: lecture, showNotes: showNotes) { materials, progress in
            let available = materials.quiz.filter { !progress.flagged.contains($0.id) }
            VStack(spacing: 0) {
                StudyToolbar(lecture: lecture)
                Divider()
                Group {
                    if let session, !session.isFinished, let item = session.current {
                        question(item, session: session, flagged: progress.flagged.contains(item.id), materials: materials)
                    } else if let session, session.isFinished {
                        results(session, materials: materials, progress: progress)
                    } else {
                        start(available: available, progress: progress, materials: materials)
                    }
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            }
            .sheet(item: $editing) { target in
                StudyItemEditor(target: target, materials: materials) { study.saveEdited($0, lectureID: lecture.id) }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .onChange(of: study.revision(lecture.id)) {
            // Материалы пересобраны: старая сессия больше не совпадает с вопросами.
            if lecture.meta.study?.createdAt != startedFor { session = nil }
        }
    }

    @State private var startedFor: Date?

    private func start(available: [StudyMaterials.QuizItem], progress: StudyProgress, materials: StudyMaterials) -> some View {
        let mistakes = progress.quizMistakes(in: materials)
        return VStack(spacing: 14) {
            Image(systemName: "checklist").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Тест: \(available.count) вопросов").font(.title2.weight(.semibold))
            if let last = progress.quizAttempts.last {
                Text("Последняя попытка: \(last.score) из \(last.total), "
                     + last.date.formatted(.dateTime.day().month().hour().minute().locale(Locale(identifier: "ru_RU"))))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Начать тест") { begin(available, onlyMistakes: false) }
                    .prominentAction()
                    .disabled(available.isEmpty)
                Button("Только ошибки (\(mistakes.count))") { begin(mistakes, onlyMistakes: true) }
                    .disabled(mistakes.isEmpty)
            }
            Text("Клавиши: 1–4 — вариант ответа, Enter — дальше.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func begin(_ items: [StudyMaterials.QuizItem], onlyMistakes: Bool) {
        startedFor = lecture.meta.study?.createdAt
        session = QuizSession(items: items, onlyMistakes: onlyMistakes)
        focused = true
    }

    private func question(_ item: StudyMaterials.QuizItem, session: QuizSession, flagged: Bool,
                          materials: StudyMaterials) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Вопрос \(session.index + 1) из \(session.items.count)").foregroundStyle(.secondary)
                    Spacer()
                    Button { editing = .quiz(item.id) } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless).help("Изменить вопрос")
                    FlagButton(lectureID: lecture.id, itemID: item.id, flagged: flagged)
                }
                MathText(markdown: item.question, large: true)
                ForEach(Array(session.currentOptions.enumerated()), id: \.offset) { position, option in
                    optionButton(position: position, option: option, item: item, answer: session.currentAnswer)
                }
                if let answer = session.currentAnswer {
                    Label(answer.correct ? "Верно" : "Неверно", systemImage: answer.correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(answer.correct ? .green : .red)
                    MathText(markdown: item.explanation)
                    HStack {
                        Spacer()
                        Button(session.index + 1 < session.items.count ? "Дальше" : "Результат") { advance() }
                            .prominentAction()
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
    }

    private func optionButton(position: Int, option: (original: Int, text: String), item: StudyMaterials.QuizItem,
                              answer: QuizSession.Answer?) -> some View {
        let isCorrect = option.original == item.correctIndex
        let isChosen = answer?.chosen == option.original
        let color: Color = answer == nil ? .secondary : isCorrect ? .green : isChosen ? .red : .secondary
        return Button {
            choose(option.original, item: item)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(position + 1)").font(.headline.monospacedDigit()).foregroundStyle(.secondary)
                MathText(markdown: option.text)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(answer == nil ? 0.07 : 0.15)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(answer == nil ? 0.2 : 0.8)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(answer != nil)
    }

    private func choose(_ original: Int, item: StudyMaterials.QuizItem) {
        guard var current = session, let correct = current.answer(original) else { return }
        session = current
        study.updateProgress(lecture.id) { $0.record(correct ? .correct : .wrong, for: item.id) }
    }

    private func advance() {
        guard var current = session else { return }
        current.next()
        session = current
        if current.isFinished {
            study.updateProgress(lecture.id) { progress in
                progress.quizAttempts.append(.init(date: JSONCoding.rounded(Date()), score: current.score,
                                                   total: current.items.count, onlyMistakes: current.onlyMistakes))
            }
        }
    }

    private func results(_ session: QuizSession, materials: StudyMaterials, progress: StudyProgress) -> some View {
        let mistakes = progress.quizMistakes(in: materials)
        let available = materials.quiz.filter { !progress.flagged.contains($0.id) }
        return VStack(spacing: 14) {
            Text("\(session.score) из \(session.items.count)").font(.system(size: 44, weight: .bold))
            Text(session.score == session.items.count ? "Отлично, без ошибок!" : "Ошибок: \(session.items.count - session.score)")
                .foregroundStyle(.secondary)
            HStack {
                Button("Пройти заново") { begin(available, onlyMistakes: false) }
                Button("Только ошибки (\(mistakes.count))") { begin(mistakes, onlyMistakes: true) }
                    .prominentAction()
                    .disabled(mistakes.isEmpty)
            }
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard let current = session, !current.isFinished, editing == nil, let item = current.current else { return .ignored }
        if let digit = Int(press.characters), (1...current.currentOptions.count).contains(digit), current.currentAnswer == nil {
            choose(current.currentOptions[digit - 1].original, item: item)
            return .handled
        }
        if press.key == .return, current.currentAnswer != nil {
            advance()
            return .handled
        }
        return .ignored
    }
}

// MARK: Карточки

struct FlashcardsView: View {
    @Environment(StudyCenter.self) private var study
    let lecture: LectureRecord
    let showNotes: () -> Void

    @State private var session: FlashcardSession?
    @State private var startedFor: Date?
    @State private var editing: EditTarget?
    @FocusState private var focused: Bool

    var body: some View {
        StudyContainer(lecture: lecture, showNotes: showNotes) { materials, progress in
            VStack(spacing: 0) {
                StudyToolbar(lecture: lecture)
                Divider()
                Group {
                    if let session, let card = session.current {
                        cardView(card, session: session, flagged: progress.flagged.contains(card.id))
                    } else if let session, session.isFinished {
                        results(session, materials: materials, progress: progress)
                    } else {
                        start(materials: materials, progress: progress)
                    }
                }
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            }
            .sheet(item: $editing) { target in
                StudyItemEditor(target: target, materials: materials) { study.saveEdited($0, lectureID: lecture.id) }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .onChange(of: study.revision(lecture.id)) {
            if lecture.meta.study?.createdAt != startedFor { session = nil }
        }
    }

    private func start(materials: StudyMaterials, progress: StudyProgress) -> some View {
        let cards = materials.flashcards.filter { !progress.flagged.contains($0.id) }
        let unknown = progress.unknownCards(in: materials)
        let known = cards.filter { progress.items[$0.id]?.result == .known }.count
        return VStack(spacing: 14) {
            Image(systemName: "rectangle.on.rectangle.angled").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Карточки: \(cards.count)").font(.title2.weight(.semibold))
            if known + unknown.count > 0 {
                Text("Знаю: \(known) · Не знаю: \(unknown.count)").foregroundStyle(.secondary)
            }
            HStack {
                Button("Начать") { begin(cards.shuffled(), onlyUnknown: false) }
                    .prominentAction()
                    .disabled(cards.isEmpty)
                Button("Повторить незнакомые (\(unknown.count))") { begin(unknown.shuffled(), onlyUnknown: true) }
                    .disabled(unknown.isEmpty)
            }
            Text("Клавиши: пробел — перевернуть, ← — не знаю, → — знаю.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func begin(_ cards: [StudyMaterials.Flashcard], onlyUnknown: Bool) {
        startedFor = lecture.meta.study?.createdAt
        session = FlashcardSession(cards: cards, onlyUnknown: onlyUnknown)
        focused = true
    }

    private func cardView(_ card: StudyMaterials.Flashcard, session: FlashcardSession, flagged: Bool) -> some View {
        VStack(spacing: 16) {
            HStack {
                Text("Карточка \(session.index + 1) из \(session.cards.count)").foregroundStyle(.secondary)
                Spacer()
                Button { editing = .flashcard(card.id) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless).help("Изменить карточку")
                FlagButton(lectureID: lecture.id, itemID: card.id, flagged: flagged)
            }
            VStack(spacing: 12) {
                Text(session.flipped ? "Ответ" : "Вопрос").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                MathText(markdown: session.flipped ? card.back : card.front, large: true)
                    .multilineTextAlignment(.center)
                    .id(session.flipped)
            }
            .padding(24)
            .frame(maxWidth: .infinity, minHeight: 240)
            .background(RoundedRectangle(cornerRadius: 14).fill(session.flipped ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.secondary.opacity(0.25)))
            .contentShape(Rectangle())
            .onTapGesture { flip() }
            .help("Щёлкните или нажмите пробел, чтобы перевернуть")
            HStack(spacing: 16) {
                Button { mark(known: false) } label: { Label("Не знаю", systemImage: "arrow.left") }
                    .controlSize(.large)
                Button { mark(known: true) } label: { Label("Знаю", systemImage: "arrow.right") }
                    .controlSize(.large)
                    .prominentAction()
            }
        }
    }

    private func flip() {
        session?.flipped.toggle()
    }

    private func mark(known: Bool) {
        guard var current = session, let card = current.current else { return }
        current.mark(known: known)
        session = current
        study.updateProgress(lecture.id) { $0.record(known ? .known : .unknown, for: card.id) }
    }

    private func results(_ session: FlashcardSession, materials: StudyMaterials, progress: StudyProgress) -> some View {
        let unknown = materials.flashcards.filter { session.unknownIDs.contains($0.id) }
        return VStack(spacing: 14) {
            Text("Знаю \(session.knownCount) из \(session.cards.count)").font(.system(size: 36, weight: .bold))
            HStack {
                Button("Ещё раз все") {
                    begin(materials.flashcards.filter { !progress.flagged.contains($0.id) }.shuffled(), onlyUnknown: false)
                }
                Button("Повторить незнакомые (\(unknown.count))") { begin(unknown.shuffled(), onlyUnknown: true) }
                    .prominentAction()
                    .disabled(unknown.isEmpty)
            }
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard session?.current != nil, editing == nil else { return .ignored }
        switch press.key {
        case .space: flip()
        case .leftArrow: mark(known: false)
        case .rightArrow: mark(known: true)
        default: return .ignored
        }
        return .handled
    }
}

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
    @Environment(\.dismiss) private var dismiss
    @State private var draft: StudyMaterials

    init(target: EditTarget, materials: StudyMaterials, save: @escaping (StudyMaterials) -> Void) {
        self.target = target
        self.materials = materials
        self.save = save
        _draft = State(initialValue: materials)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.weight(.semibold))
            Text("Можно использовать Markdown и формулы: $…$, $$…$$, \\ce{…}.").font(.caption).foregroundStyle(.secondary)
            Form { fields }
                .formStyle(.grouped)
            HStack {
                Button("Удалить", role: .destructive) { delete() }
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить") {
                    save(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.problems().isEmpty)
            }
            if !draft.problems().isEmpty {
                Text(draft.problems().joined(separator: " ")).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(18)
        .frame(width: 620, height: 560)
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
        dismiss()
    }
}
