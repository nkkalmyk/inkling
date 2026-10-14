import Foundation

/// `study.json` (SPEC, раздел 6.1). У каждого элемента стабильный `id`: на нём держатся прогресс и ручные правки.
struct StudyMaterials: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    struct Term: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var term: String
        var definition: String
    }

    enum QuestionType: String, Codable, CaseIterable, Sendable {
        case understanding, application, calculation

        var title: String {
            switch self {
            case .understanding: "На понимание"
            case .application: "На применение"
            case .calculation: "Расчётная задача"
            }
        }
    }

    enum Difficulty: String, Codable, CaseIterable, Sendable {
        case easy, medium, hard

        var title: String {
            switch self {
            case .easy: "Лёгкий"
            case .medium: "Средний"
            case .hard: "Сложный"
            }
        }
    }

    struct Question: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var type: QuestionType
        var difficulty: Difficulty
        var question: String
        var answer: String
        var solution: String?
    }

    struct QuizItem: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var question: String
        var options: [String]
        var correctIndex: Int
        var explanation: String
    }

    struct Flashcard: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var front: String
        var back: String
    }

    var schemaVersion = currentSchemaVersion
    var summary: [String]
    var terms: [Term]
    var questions: [Question]
    var quiz: [QuizItem]
    var flashcards: [Flashcard]

    /// Присваивает id по порядку (`t1`, `q1`, `z1`, `f1`): id от модели не используются.
    mutating func assignIDs() {
        for i in terms.indices { terms[i].id = "t\(i + 1)" }
        for i in questions.indices { questions[i].id = "q\(i + 1)" }
        for i in quiz.indices { quiz[i].id = "z\(i + 1)" }
        for i in flashcards.indices { flashcards[i].id = "f\(i + 1)" }
    }

    /// Новый id для элемента, добавленного вручную.
    static func nextID(prefix: String, existing: [String]) -> String {
        let used = Set(existing)
        var n = existing.count + 1
        while used.contains("\(prefix)\(n)") { n += 1 }
        return "\(prefix)\(n)"
    }

    // MARK: Схема и проверка

    /// JSON Schema для `--json-schema` (id не требуются: их присваивает приложение).
    static let jsonSchema: String = {
        let string: [String: Any] = ["type": "string", "minLength": 1]
        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["summary", "terms", "questions", "quiz", "flashcards"],
            "properties": [
                "summary": ["type": "array", "items": string, "minItems": 1],
                "terms": ["type": "array", "items": [
                    "type": "object", "required": ["term", "definition"],
                    "properties": ["id": ["type": "string"], "term": string, "definition": string],
                ]],
                "questions": ["type": "array", "minItems": 1, "items": [
                    "type": "object", "required": ["type", "difficulty", "question", "answer", "solution"],
                    "properties": [
                        "id": ["type": "string"],
                        "type": ["type": "string", "enum": QuestionType.allCases.map(\.rawValue)],
                        "difficulty": ["type": "string", "enum": Difficulty.allCases.map(\.rawValue)],
                        "question": string, "answer": string,
                        "solution": ["type": ["string", "null"]],
                    ],
                ]],
                "quiz": ["type": "array", "minItems": 1, "items": [
                    "type": "object", "required": ["question", "options", "correctIndex", "explanation"],
                    "properties": [
                        "id": ["type": "string"], "question": string,
                        "options": ["type": "array", "items": string, "minItems": 4, "maxItems": 4],
                        "correctIndex": ["type": "integer", "minimum": 0, "maximum": 3],
                        "explanation": string,
                    ],
                ]],
                "flashcards": ["type": "array", "minItems": 1, "items": [
                    "type": "object", "required": ["front", "back"],
                    "properties": ["id": ["type": "string"], "front": string, "back": string],
                ]],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }()

    /// Разбирает и проверяет ответ модели. Ошибки — по-русски, они уходят в повторный запрос (SPEC, раздел 5).
    static func parse(_ data: Data) -> Result<StudyMaterials, StudyValidationError> {
        var raw: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(.init(problems: ["Ответ должен быть JSON-объектом."]))
            }
            raw = object
        } catch {
            return .failure(.init(problems: ["Ответ не разбирается как JSON: \(error.localizedDescription)"]))
        }
        // id необязательны: подставляем пустые, потом присваиваем свои.
        for key in ["terms", "questions", "quiz", "flashcards"] {
            if let items = raw[key] as? [[String: Any]] {
                raw[key] = items.map { item in
                    var item = item
                    if !(item["id"] is String) { item["id"] = "" }
                    if key == "questions", item["solution"] == nil { item["solution"] = NSNull() }
                    return item
                }
            }
        }
        if raw["schemaVersion"] == nil { raw["schemaVersion"] = currentSchemaVersion }
        var study: StudyMaterials
        do {
            let normalized = try JSONSerialization.data(withJSONObject: raw)
            study = try JSONDecoder().decode(StudyMaterials.self, from: normalized)
        } catch let DecodingError.keyNotFound(key, context) {
            return .failure(.init(problems: ["Нет поля «\(path(context.codingPath + [key]))»."]))
        } catch let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context) {
            return .failure(.init(problems: ["Неверный тип поля «\(path(context.codingPath))»."]))
        } catch let DecodingError.dataCorrupted(context) {
            return .failure(.init(problems: ["Неверное значение поля «\(path(context.codingPath))»: \(context.debugDescription)"]))
        } catch {
            return .failure(.init(problems: [error.localizedDescription]))
        }
        study.assignIDs()
        let problems = study.problems()
        return problems.isEmpty ? .success(study) : .failure(.init(problems: problems))
    }

    private static func path(_ keys: [CodingKey]) -> String {
        keys.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined().trimmingCharacters(in: ["."])
    }

    /// Структурные ошибки, из-за которых материалы нельзя показать. Количество элементов не проверяется строго.
    func problems() -> [String] {
        var problems: [String] = []
        func empty(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if summary.isEmpty || summary.contains(where: empty) { problems.append("summary: нужны непустые пункты резюме.") }
        for (i, t) in terms.enumerated() where empty(t.term) || empty(t.definition) {
            problems.append("terms[\(i)]: пустой термин или определение.")
        }
        if questions.isEmpty { problems.append("questions: нет вопросов.") }
        for (i, q) in questions.enumerated() where empty(q.question) || empty(q.answer) {
            problems.append("questions[\(i)]: пустой вопрос или ответ.")
        }
        if quiz.isEmpty { problems.append("quiz: нет вопросов теста.") }
        for (i, z) in quiz.enumerated() {
            if z.options.count != 4 { problems.append("quiz[\(i)]: нужно ровно 4 варианта ответа, а не \(z.options.count).") }
            if !(0..<z.options.count).contains(z.correctIndex) {
                problems.append("quiz[\(i)]: correctIndex \(z.correctIndex) вне диапазона 0…\(max(z.options.count - 1, 0)).")
            }
            if z.options.contains(where: empty) || empty(z.question) || empty(z.explanation) {
                problems.append("quiz[\(i)]: пустой вопрос, вариант или объяснение.")
            }
            if Set(z.options.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }).count != z.options.count {
                problems.append("quiz[\(i)]: варианты ответа повторяются.")
            }
        }
        if flashcards.isEmpty { problems.append("flashcards: нет карточек.") }
        for (i, f) in flashcards.enumerated() where empty(f.front) || empty(f.back) {
            problems.append("flashcards[\(i)]: пустая сторона карточки.")
        }
        return problems
    }
}

struct StudyValidationError: Error, Equatable, Sendable {
    var problems: [String]

    var message: String { problems.joined(separator: "\n") }
}

/// `progress.json` (SPEC, раздел 6.2).
struct StudyProgress: Codable, Equatable, Sendable {
    enum Result: String, Codable, Sendable {
        /// Карточки.
        case known, unknown
        /// Вопросы теста.
        case correct, wrong
    }

    struct ItemState: Codable, Equatable, Sendable {
        var result: Result
        var date: Date
    }

    struct QuizAttempt: Codable, Equatable, Sendable {
        var date: Date
        var score: Int
        var total: Int
        var onlyMistakes: Bool
    }

    var schemaVersion = 1
    var items: [String: ItemState] = [:]
    var quizAttempts: [QuizAttempt] = []
    /// «Ошибка в вопросе»: элемент не считается и не показывается в самопроверке.
    var flagged: Set<String> = []

    var isEmpty: Bool { items.isEmpty && quizAttempts.isEmpty && flagged.isEmpty }

    mutating func record(_ result: Result, for id: String, at date: Date = Date()) {
        items[id] = ItemState(result: result, date: JSONCoding.rounded(date))
    }

    /// Вопросы теста, на которые последний ответ был неверным (без помеченных ошибочными).
    func quizMistakes(in study: StudyMaterials) -> [StudyMaterials.QuizItem] {
        study.quiz.filter { items[$0.id]?.result == .wrong && !flagged.contains($0.id) }
    }

    /// Карточки, которые последний раз отмечены «не знаю».
    func unknownCards(in study: StudyMaterials) -> [StudyMaterials.Flashcard] {
        study.flashcards.filter { items[$0.id]?.result == .unknown && !flagged.contains($0.id) }
    }
}

/// Файлы учебных материалов с историей в `history/study/`.
struct StudyStore: Sendable {
    let folder: URL

    var studyURL: URL { folder.appendingPathComponent("study.json") }
    var progressURL: URL { folder.appendingPathComponent("progress.json") }
    var history: HistoryStore { HistoryStore(lectureFolder: folder, category: "study", key: "study") }
    var progressHistory: HistoryStore { HistoryStore(lectureFolder: folder, category: "study", key: "progress") }

    func readStudy() -> StudyMaterials? {
        try? JSONDecoder().decode(StudyMaterials.self, from: AtomicFile.read(studyURL))
    }

    func readProgress() -> StudyProgress {
        (try? AtomicFile.readJSON(StudyProgress.self, from: progressURL)) ?? StudyProgress()
    }

    /// Записывает материалы. Если они перезаписывают прежние (пересборка), старые `study.json` и `progress.json`
    /// уходят в историю, а прогресс начинается заново (SPEC, раздел 13).
    func writeNew(_ study: StudyMaterials, previous: ArtifactInfo?, now: Date = Date()) throws {
        if FileManager.default.fileExists(atPath: studyURL.path) {
            try history.save(studyURL, info: previous, now: now)
        }
        if FileManager.default.fileExists(atPath: progressURL.path) {
            try progressHistory.save(progressURL, info: Optional<ArtifactInfo>.none, now: now)
            try FileManager.default.removeItem(at: progressURL)
        }
        try AtomicFile.writeJSON(study, to: studyURL)
    }

    /// Ручная правка: прогресс сохраняется; при первой правке результата модели прежняя версия — в историю.
    func writeEdited(_ study: StudyMaterials, previous: ArtifactInfo?, saveHistory: Bool) throws {
        if saveHistory, FileManager.default.fileExists(atPath: studyURL.path) {
            try history.save(studyURL, info: previous)
        }
        try AtomicFile.writeJSON(study, to: studyURL)
    }

    func writeProgress(_ progress: StudyProgress) throws {
        try AtomicFile.writeJSON(progress, to: progressURL)
    }
}
