import Foundation
import Testing
@testable import Inkling

/// Корректный ответ модели (id не обязательны).
enum StudyFixtures {
    static func json(quizOptions: Int = 4, correctIndex: Int = 2, extraQuestion: String = "") -> String {
        let options = (1...quizOptions).map { "\"Вариант \($0)\"" }.joined(separator: ",")
        return """
        {"summary":["Окислитель принимает электроны","Восстановитель отдаёт электроны"],
         "terms":[{"id":"x","term":"Окислитель","definition":"Принимает электроны"}],
         "questions":[{"type":"understanding","difficulty":"easy","question":"Что делает окислитель?","answer":"Принимает электроны","solution":null},
                      {"type":"calculation","difficulty":"hard","question":"Найдите $x$","answer":"$x=2$","solution":"Шаг 1. $2x=4$"}\(extraQuestion)],
         "quiz":[{"question":"Степень окисления O в $\\\\ce{H2O}$?","options":[\(options)],"correctIndex":\(correctIndex),"explanation":"Так"},
                 {"question":"Второй","options":["а","б","в","г"],"correctIndex":0,"explanation":"Потому"}],
         "flashcards":[{"front":"Окислитель","back":"Принимает электроны"},{"front":"$\\\\ce{H2O}$","back":"Вода"}]}
        """
    }
}

@Suite("study.json")
struct StudyModelTests {
    @Test func parsesAndAssignsIDs() throws {
        let study = try StudyMaterials.parse(Data(StudyFixtures.json().utf8)).get()
        #expect(study.schemaVersion == 1)
        #expect(study.terms.map(\.id) == ["t1"])
        #expect(study.questions.map(\.id) == ["q1", "q2"])
        #expect(study.quiz.map(\.id) == ["z1", "z2"])
        #expect(study.flashcards.map(\.id) == ["f1", "f2"])
        #expect(study.questions[0].solution == nil && study.questions[1].solution == "Шаг 1. $2x=4$")
        #expect(study.quiz[0].question.contains(#"\ce{H2O}"#))
    }

    @Test func missingSolutionIsNull() throws {
        let json = StudyFixtures.json().replacingOccurrences(of: #","solution":null"#, with: "")
        #expect(try StudyMaterials.parse(Data(json.utf8)).get().questions[0].solution == nil)
    }

    @Test func wrongOptionCountIsReported() {
        guard case .failure(let error) = StudyMaterials.parse(Data(StudyFixtures.json(quizOptions: 3, correctIndex: 1).utf8))
        else { Issue.record("Ожидалась ошибка"); return }
        #expect(error.message.contains("quiz[0]: нужно ровно 4 варианта ответа, а не 3."))
    }

    @Test func correctIndexOutOfRange() {
        guard case .failure(let error) = StudyMaterials.parse(Data(StudyFixtures.json(correctIndex: 4).utf8))
        else { Issue.record("Ожидалась ошибка"); return }
        #expect(error.message.contains("correctIndex 4"))
    }

    @Test func badEnumAndMissingField() {
        let badType = StudyFixtures.json().replacingOccurrences(of: #""type":"understanding""#, with: #""type":"essay""#)
        guard case .failure(let e1) = StudyMaterials.parse(Data(badType.utf8)) else { Issue.record("тип"); return }
        #expect(e1.message.contains("questions[0].type"))

        let noFlashcards = #"{"summary":["a"],"terms":[],"questions":[],"quiz":[]}"#
        guard case .failure(let e2) = StudyMaterials.parse(Data(noFlashcards.utf8)) else { Issue.record("поле"); return }
        #expect(e2.message.contains("flashcards"))

        guard case .failure = StudyMaterials.parse(Data("не json".utf8)) else { Issue.record("json"); return }
    }

    @Test func duplicateOptionsAndEmptyStrings() {
        let json = StudyFixtures.json().replacingOccurrences(of: #"["а","б","в","г"]"#, with: #"["а","а","в","г"]"#)
            .replacingOccurrences(of: #""back":"Вода""#, with: #""back":"  ""#)
        guard case .failure(let error) = StudyMaterials.parse(Data(json.utf8)) else { Issue.record("Ожидалась ошибка"); return }
        #expect(error.problems.contains("quiz[1]: варианты ответа повторяются."))
        #expect(error.problems.contains("flashcards[1]: пустая сторона карточки."))
    }

    @Test func schemaIsValidJSONWithConstraints() throws {
        let schema = try #require(try JSONSerialization.jsonObject(with: Data(StudyMaterials.jsonSchema.utf8)) as? [String: Any])
        #expect((schema["required"] as? [String])?.count == 5)
        let quiz = try #require(((schema["properties"] as? [String: Any])?["quiz"] as? [String: Any])?["items"] as? [String: Any])
        let options = try #require((quiz["properties"] as? [String: Any])?["options"] as? [String: Any])
        #expect(options["minItems"] as? Int == 4 && options["maxItems"] as? Int == 4)
    }

    @Test func roundTripAndNextID() throws {
        let study = try StudyMaterials.parse(Data(StudyFixtures.json().utf8)).get()
        let data = try JSONCoding.makeEncoder().encode(study)
        #expect(try JSONDecoder().decode(StudyMaterials.self, from: data) == study)
        #expect(StudyMaterials.nextID(prefix: "q", existing: ["q1", "q3"]) == "q4")
        #expect(StudyMaterials.nextID(prefix: "f", existing: []) == "f1")
    }
}

@Suite("Самопроверка")
struct StudySessionTests {
    private let study = try! StudyMaterials.parse(Data(StudyFixtures.json().utf8)).get()

    @Test func quizShufflesDeterministicallyAndScores() {
        var a = QuizSession(items: study.quiz, seed: 42)
        let b = QuizSession(items: study.quiz, seed: 42)
        #expect(a.currentOptions.map(\.original) == b.currentOptions.map(\.original))
        #expect(Set(a.currentOptions.map(\.original)) == [0, 1, 2, 3])
        #expect(a.currentOptions.first { $0.original == 2 }?.text == "Вариант 3")

        #expect(a.answer(2) == true)
        #expect(a.answer(0) == nil, "Второй ответ на тот же вопрос не принимается")
        a.next()
        #expect(a.answer(3) == false)
        a.next()
        #expect(a.isFinished && a.score == 1)
    }

    @Test func cannotSkipUnanswered() {
        var session = QuizSession(items: study.quiz, seed: 1)
        session.next()
        #expect(session.index == 0)
    }

    @Test func shuffleMovesCorrectAnswerAround() {
        let positions = Set((0..<40).map { seed in
            QuizSession(items: study.quiz, seed: UInt64(seed)).currentOptions.firstIndex { $0.original == 2 }!
        })
        #expect(positions.count == 4)
    }

    @Test func flashcards() {
        var session = FlashcardSession(cards: study.flashcards)
        session.flipped = true
        session.mark(known: true)
        #expect(!session.flipped)
        session.mark(known: false)
        #expect(session.isFinished && session.knownCount == 1 && session.unknownIDs == ["f2"])
    }

    @Test func progressMistakesAndFlags() {
        var progress = StudyProgress()
        progress.record(.wrong, for: "z1")
        progress.record(.correct, for: "z2")
        progress.record(.unknown, for: "f1")
        #expect(progress.quizMistakes(in: study).map(\.id) == ["z1"])
        #expect(progress.unknownCards(in: study).map(\.id) == ["f1"])
        progress.flagged.insert("z1")
        #expect(progress.quizMistakes(in: study).isEmpty)
        progress.record(.correct, for: "z1")
        progress.flagged.remove("z1")
        #expect(progress.quizMistakes(in: study).isEmpty)
    }
}

@Suite("Учебные материалы")
@MainActor
struct StudyCenterTests {
    typealias FakeEngine = EngineRouterTests.FakeEngine

    private func env(konspekt: String? = "# ОВР\n\nОкислитель принимает электроны.\n") throws -> AssemblyCenterTests.Env {
        let env = try AssemblyCenterTests.Env(pages: ["Страница"])
        if let konspekt { try KonspektStore(folder: env.lecture.folder).write(konspekt, previous: nil) }
        return env
    }

    private func center(_ env: AssemblyCenterTests.Env, _ engine: FakeEngine) -> StudyCenter {
        let router = EngineRouter(primary: engine, fallback: nil, settings: .init())
        return StudyCenter(library: env.library, router: { router })
    }

    private func waitIdle(_ center: StudyCenter, _ id: UUID) async throws {
        for _ in 0..<250 {
            if !center.isRunning(id) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Подготовка не закончилась за 5 с")
    }

    @Test func generatesWithSchemaAndSaves() async throws {
        let env = try env()
        let engine = FakeEngine([.success(StudyFixtures.json())])
        let center = center(env, engine)
        center.generate(env.lectureID)
        try await waitIdle(center, env.lectureID)

        #expect(center.errors[env.lectureID] == nil)
        let request = try #require(await engine.requests.first)
        #expect(request.format == .json(schema: StudyMaterials.jsonSchema))
        #expect(request.prompt.contains("Окислитель принимает электроны."))
        #expect(request.prompt.contains("10–15 вопросов"))
        let study = try #require(StudyStore(folder: env.lecture.folder).readStudy())
        #expect(study.quiz.count == 2)
        #expect(env.lecture.meta.study?.model == "fake")
        #expect(!center.isStale(env.lecture))
    }

    @Test func invalidAnswerIsRetriedWithProblems() async throws {
        let env = try env()
        let engine = FakeEngine([.success(StudyFixtures.json(quizOptions: 3, correctIndex: 1)), .success(StudyFixtures.json())])
        let center = center(env, engine)
        center.generate(env.lectureID)
        try await waitIdle(center, env.lectureID)
        let requests = await engine.requests
        #expect(requests.count == 2)
        #expect(requests[1].prompt.contains("Предыдущий ответ не прошёл проверку"))
        #expect(requests[1].prompt.contains("ровно 4 варианта"))
        #expect(StudyStore(folder: env.lecture.folder).readStudy() != nil)
    }

    @Test func twoInvalidAnswersFail() async throws {
        let env = try env()
        let bad = StudyFixtures.json(correctIndex: 7)
        let center = center(env, FakeEngine([.success(bad), .success(bad)]))
        center.generate(env.lectureID)
        try await waitIdle(center, env.lectureID)
        guard case .invalidOutput(let details) = center.errors[env.lectureID] else {
            Issue.record("Ожидалась invalidOutput"); return
        }
        #expect(details.contains("correctIndex 7"))
        #expect(StudyStore(folder: env.lecture.folder).readStudy() == nil)
    }

    @Test func needsKonspekt() throws {
        let env = try env(konspekt: nil)
        let center = center(env, FakeEngine([]))
        center.generate(env.lectureID)
        #expect(!center.isRunning(env.lectureID))
        #expect(center.errors[env.lectureID] != nil)
    }

    @Test func regenerationMovesProgressToHistory() async throws {
        let env = try env()
        let center = center(env, FakeEngine([.success(StudyFixtures.json()), .success(StudyFixtures.json())]))
        center.generate(env.lectureID)
        try await waitIdle(center, env.lectureID)
        center.updateProgress(env.lectureID) { $0.record(.known, for: "f1") }
        let store = StudyStore(folder: env.lecture.folder)
        #expect(store.readProgress().items["f1"]?.result == .known)

        center.generate(env.lectureID)
        try await waitIdle(center, env.lectureID)
        #expect(store.readProgress().isEmpty)
        #expect(store.history.entries().count == 1)
        let oldProgress = try #require(store.progressHistory.entries().first)
        #expect(try AtomicFile.readJSON(StudyProgress.self, from: oldProgress.file).items["f1"]?.result == .known)
    }

    @Test func konspektChangeMakesStudyStale() async throws {
        let env = try env()
        let center = center(env, FakeEngine([.success(StudyFixtures.json())]))
        center.generate(env.lectureID)
        try await waitIdle(center, env.lectureID)
        #expect(!center.isStale(env.lecture))
        env.library.saveKonspektEdit("# ОВР\n\nПравка.\n", lectureID: env.lectureID)
        #expect(center.isStale(env.lecture))
    }

    @Test func manualEditKeepsProgress() async throws {
        let env = try env()
        let center = center(env, FakeEngine([.success(StudyFixtures.json())]))
        center.generate(env.lectureID)
        try await waitIdle(center, env.lectureID)
        center.updateProgress(env.lectureID) { $0.flagged.insert("q1") }

        let store = StudyStore(folder: env.lecture.folder)
        var study = try #require(store.readStudy())
        study.flashcards[0].back = "Принимает электроны (правка)"
        center.saveEdited(study, lectureID: env.lectureID)
        #expect(store.readStudy()?.flashcards[0].back == "Принимает электроны (правка)")
        #expect(store.readProgress().flagged == ["q1"])
        #expect(env.lecture.meta.study?.manuallyEdited == true)
        #expect(store.history.entries().count == 1)
    }

    @Test func autoRunAfterAssembly() async throws {
        let env = try env(konspekt: nil)
        let router = EngineRouter(primary: FakeEngine([.success("# Конспект"), .success(StudyFixtures.json())]),
                                  fallback: nil, settings: .init(maxParallel: 1))
        let assembly = AssemblyCenter(library: env.library, router: { router }, threshold: { 40_000 })
        let study = StudyCenter(library: env.library, router: { router })
        assembly.onAssembled = { study.generate($0) }
        assembly.assemble(env.lectureID)
        for _ in 0..<250 {
            if StudyStore(folder: env.lecture.folder).readStudy() != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(StudyStore(folder: env.lecture.folder).readStudy() != nil)
        #expect(!study.isStale(env.lecture))
    }
}

/// Живая подготовка материалов с настоящим Claude Code (по флагу).
@Suite("Учебные материалы: живой вызов", .enabled(if: ProcessInfo.processInfo.environment["INKLING_LIVE_CLAUDE"] == "1"))
@MainActor
struct StudyLiveTests {
    @Test func generatesFromShortKonspekt() async throws {
        let env = try AssemblyCenterTests.Env(pages: ["x"])
        try KonspektStore(folder: env.lecture.folder).write("""
        # Окислительно-восстановительные реакции

        Окислитель принимает электроны и восстанавливается, восстановитель отдаёт электроны и окисляется.
        Пример: $\\ce{2H2 + O2 -> 2H2O}$: водород — восстановитель ($0 \\to +1$), кислород — окислитель ($0 \\to -2$).
        Степень окисления — условный заряд атома. Сумма степеней окисления в молекуле равна нулю.
        Метод электронного баланса: число отданных и принятых электронов совпадает.
        """, previous: nil)
        let router = EngineRouter(primary: ClaudeCodeEngine(config: .init()), fallback: nil, settings: .init())
        let center = StudyCenter(library: env.library, router: { router })
        center.generate(env.lectureID)
        for _ in 0..<1500 where center.isRunning(env.lectureID) { try await Task.sleep(for: .milliseconds(200)) }
        #expect(center.errors[env.lectureID] == nil, "\(String(describing: center.errors[env.lectureID]))")
        let study = try #require(StudyStore(folder: env.lecture.folder).readStudy())
        print("Резюме: \(study.summary.count), термины: \(study.terms.count), вопросы: \(study.questions.count), "
              + "тест: \(study.quiz.count), карточки: \(study.flashcards.count)")
        print("Пример вопроса теста: \(study.quiz[0].question) → \(study.quiz[0].options[study.quiz[0].correctIndex])")
        #expect(study.quiz.allSatisfy { $0.options.count == 4 })
        #expect(study.questions.count >= 5)
    }
}
