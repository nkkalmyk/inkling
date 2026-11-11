import SwiftUI

// MARK: Карточки

struct FlashcardsView: View {
    @Environment(Library.self) private var library
    @Environment(\.lectureRequests) private var requests
    @Environment(\.isActiveTab) private var isActive
    let lecture: LectureRecord
    let showNotes: () -> Void

    var body: some View {
        StudyContainer(lecture: lecture, showNotes: showNotes) { materials, progress in
            start(materials: materials, progress: progress)
                .frame(maxWidth: ReadingWidth.focused)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(Spacing.xxl)
                // «Лекция → Повторить карточки» (⌘R): все карточки, кроме помеченных, как кнопкой «Начать».
                .task(id: requests.wrappedValue.reviewCards && isActive) {
                    guard requests.wrappedValue.reviewCards, isActive else { return }
                    requests.wrappedValue.reviewCards = false
                    let cards = materials.flashcards.filter { !progress.flagged.contains($0.id) }
                    if !cards.isEmpty { begin(cards.shuffled(), onlyUnknown: false) }
                }
        }
    }

    private func start(materials: StudyMaterials, progress: StudyProgress) -> some View {
        let cards = materials.flashcards.filter { !progress.flagged.contains($0.id) }
        let unknown = progress.unknownCards(in: materials)
        let known = cards.filter { progress.items[$0.id]?.result == .known }.count
        return StudyStart(systemImage: "rectangle.on.rectangle.angled", title: "Карточки: \(cards.count)",
                          subtitle: known + unknown.count > 0 ? "Знаю: \(known) · Не знаю: \(unknown.count)" : nil,
                          hint: "Повторение открывается на всё окно (⌘R). Пробел — перевернуть, ← — не знаю, "
                              + "→ — знаю, Esc — закончить.") {
            Button("Повторить незнакомые (\(unknown.count))") { begin(unknown.shuffled(), onlyUnknown: true) }
                .disabled(unknown.isEmpty)
            Button("Начать") { begin(cards.shuffled(), onlyUnknown: false) }
                .prominentAction()
                .disabled(cards.isEmpty)
        }
    }

    private func begin(_ cards: [StudyMaterials.Flashcard], onlyUnknown: Bool) {
        library.review = FlashcardReview(lectureID: lecture.id, cards: cards, onlyUnknown: onlyUnknown,
                                         materialsCreatedAt: lecture.meta.study?.createdAt)
    }
}

/// Сеанс повторения карточек, запущенный с вкладки «Карточки».
struct FlashcardReview: Identifiable, Equatable {
    let id = UUID()
    let lectureID: UUID
    let cards: [StudyMaterials.Flashcard]
    let onlyUnknown: Bool
    /// Материалы, по которым начат сеанс: если их подготовили заново, сеанс закрывается.
    let materialsCreatedAt: Date?
}

/// Режим повторения: карточка на всё окно поверх колонок, без тулбара (ContentView). Esc или ✕ — выход.
/// Материалы и прогресс читает в фоне, как вкладки самопроверки; ответы и пометки сохраняет сразу.
struct FlashcardReviewView: View {
    @Environment(Library.self) private var library
    @Environment(StudyCenter.self) private var study
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let review: FlashcardReview
    let lecture: LectureRecord

    @State private var session: FlashcardSession
    @State private var loaded: LoadedStudyFiles?
    @State private var editing: EditTarget?
    /// Куда ушла последняя карточка: «знаю» — вправо, «не знаю» — влево.
    @State private var lastKnown = true
    @FocusState private var focused: Bool

    init(review: FlashcardReview, lecture: LectureRecord) {
        self.review = review
        self.lecture = lecture
        _session = State(initialValue: FlashcardSession(cards: review.cards, onlyUnknown: review.onlyUnknown))
    }

    var body: some View {
        VStack(spacing: Spacing.xxl) {
            header
            Group {
                if let card = session.current {
                    cardView(card)
                } else {
                    results
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: ReadingWidth.focused)
        .padding(Spacing.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surfaceStudy)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(phases: .down, action: handleKey)
        .task(id: study.revision(lecture.id)) {
            let read = await loadStudyFiles(study.store(lecture))
            if !Task.isCancelled { loaded = read }
        }
        .onChange(of: lecture.meta.study?.createdAt) { if lecture.meta.study?.createdAt != review.materialsCreatedAt { close() } }
        .sheet(item: $editing) { target in
            if let materials = loaded?.materials {
                StudyItemEditor(target: target, materials: materials) { study.saveEdited($0, lectureID: lecture.id) }
            }
        }
        .accessibilityAddTraits(.isModal)
    }

    private var header: some View {
        HStack(spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Повторение карточек").font(.headline)
                Text("\(lecture.meta.topic) · \(lecture.meta.subject)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Готово", action: close)
                .keyboardShortcut(.cancelAction)
                .help("Закончить повторение (Esc)")
        }
    }

    private func cardView(_ card: StudyMaterials.Flashcard) -> some View {
        VStack(spacing: Spacing.l) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack {
                    Text("Карточка \(session.index + 1) из \(session.cards.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    IconButton("Изменить карточку", systemImage: "pencil") { editing = .flashcard(card.id) }
                        .disabled(loaded?.materials == nil)
                    FlagButton(lectureID: lecture.id, itemID: card.id,
                               flagged: loaded?.progress.flagged.contains(card.id) ?? false)
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

    private var results: some View {
        let unknown = session.cards.filter { session.unknownIDs.contains($0.id) }
        return VStack(spacing: Spacing.l) {
            ScoreRing(score: session.knownCount, total: session.cards.count)
            Text(unknown.isEmpty ? "Все карточки знакомы!" : "Незнакомых: \(unknown.count)")
                .font(.screenTitle)
            HStack(spacing: Spacing.m) {
                Button("Ещё раз все") { restart(session.cards.shuffled(), onlyUnknown: false) }
                Button("Повторить незнакомые (\(unknown.count))") { restart(unknown.shuffled(), onlyUnknown: true) }
                    .prominentAction()
                    .disabled(unknown.isEmpty)
            }
            .controlSize(.large)
        }
    }

    private func flip() {
        withMotion(.card, reduceMotion: reduceMotion) { session.flipped.toggle() }
    }

    private func mark(known: Bool) {
        guard let card = session.current else { return }
        lastKnown = known
        withMotion(.card, reduceMotion: reduceMotion) { session.mark(known: known) }
        study.updateProgress(lecture.id) { $0.record(known ? .known : .unknown, for: card.id) }
    }

    private func restart(_ cards: [StudyMaterials.Flashcard], onlyUnknown: Bool) {
        withMotion(.standard, reduceMotion: reduceMotion) {
            session = FlashcardSession(cards: cards, onlyUnknown: onlyUnknown)
        }
    }

    private func close() {
        withMotion(.standard, reduceMotion: reduceMotion) { library.review = nil }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard session.current != nil, editing == nil else { return .ignored }
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
