import SwiftUI

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
    @Environment(\.isActiveTab) private var isActive

    var body: some View {
        StudyContainer(lecture: lecture, showNotes: showNotes) { materials, progress in
            let available = materials.quiz.filter { !progress.flagged.contains($0.id) }
            VStack(spacing: 0) {
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
                .padding(Spacing.xxl)
            }
            .sheet(item: $editing) { target in
                StudyItemEditor(target: target, materials: materials) { study.saveEdited($0, lectureID: lecture.id) }
            }
        }
        .focusable(isActive)
        .focused($focused)
        .focusEffectDisabled()
        .onChange(of: isActive, initial: true) { if isActive { focused = true } }
        .onKeyPress(phases: .down) { press in isActive ? handleKey(press) : .ignored }
        .onChange(of: study.revision(lecture.id)) {
            // Материалы пересобраны: старая сессия больше не совпадает с вопросами.
            if lecture.meta.study?.createdAt != startedFor { session = nil }
        }
    }

    private func start(available: [StudyMaterials.QuizItem], progress: StudyProgress, materials: StudyMaterials) -> some View {
        let mistakes = progress.quizMistakes(in: materials)
        let last = progress.quizAttempts.last
        return StudyStart(systemImage: "checklist", title: "Тест: \(UIFormat.count(available.count, "вопрос", "вопроса", "вопросов"))",
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
