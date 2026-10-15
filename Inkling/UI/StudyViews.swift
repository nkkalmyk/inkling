import SwiftUI

/// Общая обвязка вкладок «Вопросы», «Тест», «Карточки»: тёплый фон зоны, подготовка материалов,
/// «Устарело», ошибки.
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
        .background(Color.surfaceStudy)
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
        EmptyState("Учебных материалов пока нет", systemImage: "graduationcap",
                   description: hasKonspekt
                       ? "Вопросы, тест и карточки готовятся по конспекту. Проверьте конспект перед запуском, "
                           + "чтобы ошибки распознавания не попали в карточки."
                       : "Сначала соберите конспект на вкладке «Конспект».",
                   tint: .accentColor) {
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
private struct StudyToolbar<Trailing: View>: View {
    @Environment(StudyCenter.self) private var study
    let lecture: LectureRecord
    @ViewBuilder var trailing: () -> Trailing
    @State private var confirm = false

    var body: some View {
        HStack(spacing: Spacing.m) {
            if let info = lecture.meta.study {
                Text([info.model, info.updatedAt.stamp, info.manuallyEdited ? "правлено вручную" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ReviewBadge(engine: info.engine, manuallyEdited: info.manuallyEdited)
            }
            Spacer()
            trailing()
            Button("Подготовить заново") {
                let progress = study.store(lecture).readProgress()
                if lecture.meta.study?.manuallyEdited == true || !progress.isEmpty { confirm = true }
                else { study.generate(lecture.id) }
            }
            .disabled(study.isRunning(lecture.id))
        }
        .font(.meta)
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .confirmationDialog("Подготовить материалы заново?", isPresented: $confirm) {
            Button("Подготовить") { study.generate(lecture.id) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Прогресс самопроверки начнётся заново. Старые материалы и прогресс сохранятся в истории.")
        }
    }
}

extension StudyToolbar where Trailing == EmptyView {
    init(lecture: LectureRecord) {
        self.init(lecture: lecture) { EmptyView() }
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
            Label(flagged ? "Снять пометку «ошибка в вопросе»" : "Ошибка в вопросе",
                  systemImage: flagged ? "flag.fill" : "flag")
                .labelStyle(.iconOnly)
                .foregroundStyle(flagged ? Color.statusError : .secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .help(flagged ? "Снять пометку «ошибка в вопросе»" : "Ошибка в вопросе: не учитывать и не показывать в самопроверке")
    }
}

/// Начальный экран теста и карточек: крупный символ, счёт, кнопки, подсказка по клавишам.
private struct StudyStart<Actions: View>: View {
    let systemImage: String
    let title: String
    var subtitle: String?
    let hint: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: Spacing.l) {
            Image(systemName: systemImage)
                .font(.illustration)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(title).font(.screenTitle)
            if let subtitle {
                Text(subtitle).foregroundStyle(.secondary)
            }
            HStack(spacing: Spacing.m) { actions() }
                .controlSize(.large)
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
    }
}

// MARK: Вопросы

private enum QuestionsItem: Hashable {
    case summary, terms
    case question(String)
}

struct QuestionsView: View {
    @Environment(StudyCenter.self) private var study
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let lecture: LectureRecord
    let showNotes: () -> Void

    @State private var typeFilter: StudyMaterials.QuestionType?
    @State private var difficultyFilter: StudyMaterials.Difficulty?
    @State private var selection: QuestionsItem? = .summary
    @State private var revealed: Set<String> = []
    @State private var editing: EditTarget?
    @FocusState private var listFocused: Bool

    var body: some View {
        StudyContainer(lecture: lecture, showNotes: showNotes) { materials, progress in
            let items = materials.questions.filter {
                (typeFilter == nil || $0.type == typeFilter) && (difficultyFilter == nil || $0.difficulty == difficultyFilter)
            }
            VStack(spacing: 0) {
                StudyToolbar(lecture: lecture)
                Divider()
                HSplitView {
                    VStack(spacing: 0) {
                        filters.padding(Spacing.s)
                        list(materials: materials, items: items, progress: progress)
                    }
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 360)
                    detail(materials: materials, progress: progress)
                        .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .sheet(item: $editing) { target in
                StudyItemEditor(target: target, materials: materials) { updated in
                    study.saveEdited(updated, lectureID: lecture.id)
                }
            }
        }
        .onAppear { listFocused = true }
    }

    private var filters: some View {
        HStack(spacing: Spacing.s) {
            Picker("Тип", selection: $typeFilter) {
                Text("Все типы").tag(StudyMaterials.QuestionType?.none)
                ForEach(StudyMaterials.QuestionType.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
            }
            Picker("Сложность", selection: $difficultyFilter) {
                Text("Любая сложность").tag(StudyMaterials.Difficulty?.none)
                ForEach(StudyMaterials.Difficulty.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
            }
        }
        .labelsHidden()
        .controlSize(.small)
    }

    private func list(materials: StudyMaterials, items: [StudyMaterials.Question], progress: StudyProgress) -> some View {
        List(selection: $selection) {
            Section {
                Label("Кратко", systemImage: "text.alignleft").tag(QuestionsItem.summary)
                if !materials.terms.isEmpty {
                    Label("Термины (\(materials.terms.count))", systemImage: "character.book.closed")
                        .tag(QuestionsItem.terms)
                }
            }
            Section("Вопросы (\(items.count))") {
                ForEach(items) { question in
                    let flagged = progress.flagged.contains(question.id)
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(MathText.preview(question.question))
                            .lineLimit(2)
                        Text("\(question.type.title) · \(question.difficulty.title)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, Spacing.xxs)
                    .opacity(flagged ? 0.5 : 1)
                    .tag(QuestionsItem.question(question.id))
                }
            }
        }
        .listStyle(.sidebar)
        .focused($listFocused)
        .onKeyPress(.space) {
            guard case .question(let id) = selection else { return .ignored }
            toggleReveal(id)
            return .handled
        }
    }

    @ViewBuilder
    private func detail(materials: StudyMaterials, progress: StudyProgress) -> some View {
        ScrollView {
            Group {
                switch selection {
                case .summary, nil:
                    summary(materials)
                case .terms:
                    terms(materials)
                case .question(let id):
                    if let question = materials.questions.first(where: { $0.id == id }) {
                        questionCard(question, flagged: progress.flagged.contains(question.id))
                    }
                }
            }
            .padding(Spacing.xxl)
            .frame(maxWidth: ReadingWidth.focused, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func summary(_ materials: StudyMaterials) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Кратко").font(.sectionTitle)
            ForEach(Array(materials.summary.enumerated()), id: \.offset) { _, point in
                HStack(alignment: .top, spacing: Spacing.s) {
                    // Маркер по середине первой строки текста для чтения (интерлиньяж ~1,6 кегля).
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                        .padding(.top, (Font.readingSize * 1.6 - 6) / 2)
                        .accessibilityHidden(true)
                    MathText(markdown: point)
                }
            }
        }
    }

    private func terms(_ materials: StudyMaterials) -> some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text("Термины").font(.sectionTitle)
            ForEach(materials.terms) { term in
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    MathText(markdown: "**\(term.term)**")
                    MathText(markdown: term.definition).foregroundStyle(.secondary)
                }
                .padding(Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .surface(.studyRaised)
            }
        }
    }

    private func questionCard(_ q: StudyMaterials.Question, flagged: Bool) -> some View {
        let isRevealed = revealed.contains(q.id)
        return VStack(alignment: .leading, spacing: Spacing.l) {
            HStack(spacing: Spacing.s) {
                Chip(q.type.title)
                Chip(q.difficulty.title, style: .accent)
                if flagged { Chip("Ошибка в вопросе", style: .error) }
                Spacer()
                IconButton("Изменить вопрос", systemImage: "pencil") { editing = .question(q.id) }
                FlagButton(lectureID: lecture.id, itemID: q.id, flagged: flagged)
            }
            MathText(markdown: q.question, large: true)
            if isRevealed {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("Ответ").font(.label).foregroundStyle(.secondary)
                    MathText(markdown: q.answer)
                    if let solution = q.solution, !solution.isEmpty {
                        Text("Решение").font(.label).foregroundStyle(.secondary).padding(.top, Spacing.xs)
                        MathText(markdown: solution)
                    }
                }
                .padding(Spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .surface(.studyRaised)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
            HStack {
                Button(isRevealed ? "Скрыть ответ" : "Показать ответ") { toggleReveal(q.id) }
                Spacer()
                Text("Пробел — ответ, ↑↓ — другой вопрос").font(.caption).foregroundStyle(.secondary)
            }
        }
        .opacity(flagged ? 0.6 : 1)
    }

    private func toggleReveal(_ id: String) {
        withMotion(.standard, reduceMotion: reduceMotion) {
            if revealed.contains(id) { revealed.remove(id) } else { revealed.insert(id) }
        }
    }
}

// MARK: Тест

struct QuizView: View {
    @Environment(StudyCenter.self) private var study
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let lecture: LectureRecord
    let showNotes: () -> Void

    @State private var session: QuizSession?
    @State private var startedFor: Date?
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
                        question(item, session: session, flagged: progress.flagged.contains(item.id))
                    } else if let session, session.isFinished {
                        results(session, materials: materials, progress: progress)
                    } else {
                        start(available: available, progress: progress, materials: materials)
                    }
                }
                .frame(maxWidth: ReadingWidth.focused)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(Spacing.xl)
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

    private func start(available: [StudyMaterials.QuizItem], progress: StudyProgress, materials: StudyMaterials) -> some View {
        let mistakes = progress.quizMistakes(in: materials)
        let last = progress.quizAttempts.last
        return StudyStart(systemImage: "checklist", title: "Тест: \(available.count) вопросов",
                          subtitle: last.map { "Последняя попытка: \($0.score) из \($0.total), \($0.date.stamp)" },
                          hint: "Клавиши: 1–4 — вариант ответа, Return — дальше.") {
            Button("Только ошибки (\(mistakes.count))") { begin(mistakes, onlyMistakes: true) }
                .disabled(mistakes.isEmpty)
            Button("Начать тест") { begin(available, onlyMistakes: false) }
                .prominentAction()
                .disabled(available.isEmpty)
        }
    }

    private func begin(_ items: [StudyMaterials.QuizItem], onlyMistakes: Bool) {
        startedFor = lecture.meta.study?.createdAt
        withMotion(.standard, reduceMotion: reduceMotion) {
            session = QuizSession(items: items, onlyMistakes: onlyMistakes)
        }
        focused = true
    }

    private func question(_ item: StudyMaterials.QuizItem, session: QuizSession, flagged: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack {
                        Text("Вопрос \(session.index + 1) из \(session.items.count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Spacer()
                        IconButton("Изменить вопрос", systemImage: "pencil") { editing = .quiz(item.id) }
                        FlagButton(lectureID: lecture.id, itemID: item.id, flagged: flagged)
                    }
                    ProgressView(value: Double(session.index), total: Double(max(session.items.count, 1)))
                        .tint(.accentColor)
                        .motion(.standard, value: session.index)
                }
                MathText(markdown: item.question, large: true)
                VStack(spacing: Spacing.s) {
                    ForEach(Array(session.currentOptions.enumerated()), id: \.offset) { position, option in
                        optionButton(position: position, option: option, item: item, answer: session.currentAnswer)
                    }
                }
                if let answer = session.currentAnswer {
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        Label(answer.correct ? "Верно" : "Неверно",
                              systemImage: answer.correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.headline)
                            .foregroundStyle(answer.correct ? Color.statusSuccess : Color.statusError)
                            .symbolEffect(.bounce, value: reduceMotion ? 0 : session.index)
                        MathText(markdown: item.explanation)
                        HStack {
                            Spacer()
                            Button(session.index + 1 < session.items.count ? "Дальше" : "Результат") { advance() }
                                .prominentAction()
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(Spacing.l)
                    .surface(.studyRaised)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .id(item.id)
            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                               removal: .move(edge: .leading).combined(with: .opacity)))
        }
    }

    private func optionButton(position: Int, option: (original: Int, text: String), item: StudyMaterials.QuizItem,
                              answer: QuizSession.Answer?) -> some View {
        let isCorrect = option.original == item.correctIndex
        let isChosen = answer?.chosen == option.original
        let state: QuizOptionState = switch (answer, isCorrect, isChosen) {
        case (nil, _, _): .idle
        case (_, true, true): .correct
        case (_, false, true): .wrong
        case (_, true, false): .missedCorrect
        case (_, false, false): .dimmed
        }
        return Button {
            choose(option.original, item: item)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                Text("\(position + 1)").font(.headline.monospacedDigit()).foregroundStyle(.secondary)
                MathText(markdown: option.text)
            }
        }
        .buttonStyle(QuizOptionStyle(state: state))
        .allowsHitTesting(answer == nil)
        .accessibilityHint(answer == nil ? "Клавиша \(position + 1)" : "")
    }

    private func choose(_ original: Int, item: StudyMaterials.QuizItem) {
        guard var current = session, let correct = current.answer(original) else { return }
        withMotion(.standard, reduceMotion: reduceMotion) { session = current }
        study.updateProgress(lecture.id) { $0.record(correct ? .correct : .wrong, for: item.id) }
    }

    private func advance() {
        guard var current = session else { return }
        current.next()
        withMotion(.standard, reduceMotion: reduceMotion) { session = current }
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
        let perfect = session.score == session.items.count
        return VStack(spacing: Spacing.l) {
            ScoreRing(score: session.score, total: session.items.count)
            Text(perfect ? "Отлично, без ошибок!" : "Ошибок: \(session.items.count - session.score)")
                .font(.screenTitle)
            HStack(spacing: Spacing.m) {
                Button("Пройти заново") { begin(available, onlyMistakes: false) }
                Button("Только ошибки (\(mistakes.count))") { begin(mistakes, onlyMistakes: true) }
                    .prominentAction()
                    .disabled(mistakes.isEmpty)
            }
            .controlSize(.large)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let lecture: LectureRecord
    let showNotes: () -> Void

    @State private var session: FlashcardSession?
    @State private var startedFor: Date?
    @State private var editing: EditTarget?
    /// Куда ушла последняя карточка: «знаю» — вправо, «не знаю» — влево.
    @State private var lastKnown = true
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
                .frame(maxWidth: ReadingWidth.focused)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(Spacing.xl)
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
        return StudyStart(systemImage: "rectangle.on.rectangle.angled", title: "Карточки: \(cards.count)",
                          subtitle: known + unknown.count > 0 ? "Знаю: \(known) · Не знаю: \(unknown.count)" : nil,
                          hint: "Клавиши: пробел — перевернуть, ← — не знаю, → — знаю.") {
            Button("Повторить незнакомые (\(unknown.count))") { begin(unknown.shuffled(), onlyUnknown: true) }
                .disabled(unknown.isEmpty)
            Button("Начать") { begin(cards.shuffled(), onlyUnknown: false) }
                .prominentAction()
                .disabled(cards.isEmpty)
        }
    }

    private func begin(_ cards: [StudyMaterials.Flashcard], onlyUnknown: Bool) {
        startedFor = lecture.meta.study?.createdAt
        withMotion(.standard, reduceMotion: reduceMotion) {
            session = FlashcardSession(cards: cards, onlyUnknown: onlyUnknown)
        }
        focused = true
    }

    private func cardView(_ card: StudyMaterials.Flashcard, session: FlashcardSession, flagged: Bool) -> some View {
        VStack(spacing: Spacing.l) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack {
                    Text("Карточка \(session.index + 1) из \(session.cards.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    IconButton("Изменить карточку", systemImage: "pencil") { editing = .flashcard(card.id) }
                    FlagButton(lectureID: lecture.id, itemID: card.id, flagged: flagged)
                }
                ProgressView(value: Double(session.index), total: Double(max(session.cards.count, 1)))
                    .tint(.accentColor)
                    .motion(.standard, value: session.index)
            }
            ZStack {
                FlipCard(front: card.front, back: card.back, flipped: session.flipped, reduceMotion: reduceMotion)
                    .id(card.id)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .scale(scale: 0.96).combined(with: .opacity),
                        removal: .move(edge: lastKnown ? .trailing : .leading).combined(with: .opacity)))
            }
            .contentShape(Rectangle())
            .onTapGesture { flip() }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Перевернуть") { flip() }
            .help("Щёлкните или нажмите пробел, чтобы перевернуть")
            HStack(spacing: Spacing.l) {
                Button { mark(known: false) } label: { Label("Не знаю", systemImage: "arrow.left") }
                Button { mark(known: true) } label: { Label("Знаю", systemImage: "arrow.right") }
                    .prominentAction()
            }
            .controlSize(.large)
        }
    }

    private func flip() {
        withMotion(.card, reduceMotion: reduceMotion) { session?.flipped.toggle() }
    }

    private func mark(known: Bool) {
        guard var current = session, let card = current.current else { return }
        lastKnown = known
        current.mark(known: known)
        withMotion(.card, reduceMotion: reduceMotion) { session = current }
        study.updateProgress(lecture.id) { $0.record(known ? .known : .unknown, for: card.id) }
    }

    private func results(_ session: FlashcardSession, materials: StudyMaterials, progress: StudyProgress) -> some View {
        let unknown = materials.flashcards.filter { session.unknownIDs.contains($0.id) }
        return VStack(spacing: Spacing.l) {
            ScoreRing(score: session.knownCount, total: session.cards.count)
            Text(unknown.isEmpty ? "Все карточки знакомы!" : "Незнакомых: \(unknown.count)")
                .font(.screenTitle)
            HStack(spacing: Spacing.m) {
                Button("Ещё раз все") {
                    begin(materials.flashcards.filter { !progress.flagged.contains($0.id) }.shuffled(), onlyUnknown: false)
                }
                Button("Повторить незнакомые (\(unknown.count))") { begin(unknown.shuffled(), onlyUnknown: true) }
                    .prominentAction()
                    .disabled(unknown.isEmpty)
            }
            .controlSize(.large)
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

/// Флеш-карточка с переворотом вокруг вертикальной оси. При «Уменьшить движение» стороны просто сменяются.
private struct FlipCard: View {
    let front: String
    let back: String
    let flipped: Bool
    let reduceMotion: Bool

    var body: some View {
        Group {
            if reduceMotion {
                ZStack {
                    if flipped {
                        CardFace(title: "Ответ", text: back, flipped: true).transition(.opacity)
                    } else {
                        CardFace(title: "Вопрос", text: front, flipped: false).transition(.opacity)
                    }
                }
            } else {
                RotatingCard(front: front, back: back, angle: flipped ? 180 : 0)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(flipped ? "Ответ: \(back)" : "Вопрос: \(front)")
    }
}

/// Поворот карточки: угол анимируется, и сторона выбирается по текущему углу,
/// так что лицо сменяется ровно на ребре (90°). Обратная сторона развёрнута, чтобы читаться после поворота.
@Animatable
private struct RotatingCard: View {
    @AnimatableIgnored var front: String
    @AnimatableIgnored var back: String
    var angle: Double

    var body: some View {
        ZStack {
            if angle < 90 {
                CardFace(title: "Вопрос", text: front, flipped: false)
            } else {
                CardFace(title: "Ответ", text: back, flipped: true)
                    .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
            }
        }
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
    }
}

private struct CardFace: View {
    let title: String
    let text: String
    let flipped: Bool

    var body: some View {
        VStack(spacing: Spacing.m) {
            Text(title).font(.label).foregroundStyle(.secondary)
            MathText(markdown: text, large: true)
                .multilineTextAlignment(.center)
        }
        .padding(Spacing.xxl)
        .frame(maxWidth: .infinity, minHeight: 260)
        .surface(flipped ? .raised : .studyRaised)
        .overlay(RoundedRectangle.ds(Radius.card).strokeBorder(Color.accentColor.opacity(flipped ? 0.5 : 0.2)))
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
