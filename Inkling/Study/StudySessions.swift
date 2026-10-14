import Foundation

/// Детерминированный генератор (SplitMix64): перемешивание вариантов воспроизводимо в тестах.
struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Прохождение теста (SPEC, раздел 7): по одному вопросу, варианты перемешаны, после ответа — объяснение.
struct QuizSession: Equatable, Sendable {
    struct Answer: Equatable, Sendable {
        var chosen: Int
        var correct: Bool
    }

    let items: [StudyMaterials.QuizItem]
    let onlyMistakes: Bool
    /// Для каждого вопроса — исходные индексы вариантов в порядке показа.
    let optionOrder: [String: [Int]]
    private(set) var index = 0
    private(set) var answers: [String: Answer] = [:]

    init(items: [StudyMaterials.QuizItem], onlyMistakes: Bool = false, seed: UInt64 = UInt64.random(in: 0...UInt64.max)) {
        var generator = SeededGenerator(seed: seed)
        self.items = items
        self.onlyMistakes = onlyMistakes
        optionOrder = Dictionary(uniqueKeysWithValues: items.map { item in
            (item.id, Array(item.options.indices).shuffled(using: &generator))
        })
    }

    var current: StudyMaterials.QuizItem? { index < items.count ? items[index] : nil }
    var isFinished: Bool { index >= items.count }
    var score: Int { answers.values.filter(\.correct).count }

    /// Варианты текущего вопроса в порядке показа: (исходный индекс, текст).
    var currentOptions: [(original: Int, text: String)] {
        guard let item = current else { return [] }
        return (optionOrder[item.id] ?? Array(item.options.indices)).map { ($0, item.options[$0]) }
    }

    var currentAnswer: Answer? { current.flatMap { answers[$0.id] } }

    /// Ответ по исходному индексу варианта. Повторный ответ на тот же вопрос игнорируется.
    @discardableResult
    mutating func answer(_ original: Int) -> Bool? {
        guard let item = current, answers[item.id] == nil else { return nil }
        let correct = original == item.correctIndex
        answers[item.id] = Answer(chosen: original, correct: correct)
        return correct
    }

    mutating func next() {
        guard current.map({ answers[$0.id] != nil }) ?? false else { return }
        index += 1
    }

    static func == (lhs: QuizSession, rhs: QuizSession) -> Bool {
        lhs.items == rhs.items && lhs.index == rhs.index && lhs.answers == rhs.answers && lhs.optionOrder == rhs.optionOrder
    }
}

/// Прохождение карточек: «знаю / не знаю», в конце — итог.
struct FlashcardSession: Equatable, Sendable {
    let cards: [StudyMaterials.Flashcard]
    let onlyUnknown: Bool
    private(set) var index = 0
    var flipped = false
    private(set) var results: [String: Bool] = [:]

    init(cards: [StudyMaterials.Flashcard], onlyUnknown: Bool = false) {
        self.cards = cards
        self.onlyUnknown = onlyUnknown
    }

    var current: StudyMaterials.Flashcard? { index < cards.count ? cards[index] : nil }
    var isFinished: Bool { index >= cards.count }
    var knownCount: Int { results.values.filter { $0 }.count }
    var unknownIDs: [String] { cards.map(\.id).filter { results[$0] == false } }

    mutating func mark(known: Bool) {
        guard let card = current else { return }
        results[card.id] = known
        index += 1
        flipped = false
    }
}
