import Foundation
import Testing
@testable import Inkling

@Suite("Учебная сборка: план и промпт")
struct StudyAssemblyPlanTests {
    private func meta(pages: Int) -> LectureMeta {
        var meta = LectureMeta(subject: "Высшая алгебра", topic: "Матрицы", date: .d("2026-10-14"))
        meta.notes = (0..<pages).map { NotePage(id: "p\($0)", source: .image(file: "p\($0).jpg"), crop: .original, addedAt: Date()) }
        return meta
    }

    private func input(texts: [String: String] = [:], slides: [String] = []) -> AssemblyInput {
        var input = AssemblyInput()
        input.notes = texts.sorted { $0.key < $1.key }.map { AssemblyPage(id: $0.key, number: Int($0.key.dropFirst())! + 1, text: $0.value) }
        input.slides = slides.enumerated().map { AssemblyPage(id: "s\($0.offset)", number: $0.offset + 1, text: $0.element) }
        return input
    }

    private let paths = LecturePaths(folder: URL(fileURLWithPath: "/tmp/lecture"))

    @Test func shortLectureIsOnePartWithAllPhotos() throws {
        let plan = try #require(StudyAssemblyPlanner.plan(meta: meta(pages: 4), input: input(texts: ["p0": "a"]), paths: paths,
                                                          fileExists: { _ in true }))
        #expect(plan.parts.count == 1 && plan.calls == 1)
        #expect(plan.parts[0].notes.map(\.number) == [1, 2, 3, 4])
        // Страница без расшифровки всё равно идёт: у модели есть фото.
        #expect(plan.parts[0].notes[1].draft.isEmpty)
        #expect(plan.parts[0].notes[0].draft == "a")
    }

    @Test func typicalLectureIsOneCallAndLongOnesSplitWithOnePageOverlap() throws {
        let typical = try #require(StudyAssemblyPlanner.plan(meta: meta(pages: 10), input: input(), paths: paths, fileExists: { _ in true }))
        #expect(typical.parts.count == 1 && !typical.needsMerge)
        let plan = try #require(StudyAssemblyPlanner.plan(meta: meta(pages: 14), input: input(), paths: paths, fileExists: { _ in true }))
        #expect(plan.parts.map { $0.notes.map(\.number) } == [Array(1...10), Array(10...14)])
        #expect(plan.needsMerge && plan.calls == 3 && plan.imageCount == 15)
    }

    @Test func pagesWithoutPhotoAreSkippedAndSlidesOnlyFallsBackToText() throws {
        let missing = try #require(StudyAssemblyPlanner.plan(meta: meta(pages: 3), input: input(), paths: paths,
                                                             fileExists: { !$0.lastPathComponent.hasPrefix("p1") }))
        #expect(missing.parts[0].notes.map(\.number) == [1, 3])
        let slidesOnly = try #require(StudyAssemblyPlanner.plan(meta: meta(pages: 0), input: input(slides: ["Слайд А", "Слайд Б"]),
                                                                paths: paths, fileExists: { _ in false }))
        #expect(slidesOnly.parts[0].notes.isEmpty && slidesOnly.parts[0].slides.count == 2)
        #expect(StudyAssemblyPlanner.plan(meta: meta(pages: 0), input: input(), paths: paths, fileExists: { _ in false }) == nil)
    }

    @Test func promptListsPhotosDraftsAndSlides() throws {
        let part = StudyPart(
            notes: [StudyPage(id: "p0", number: 1, image: URL(fileURLWithPath: "/x/p0.jpg"), draft: "Черновик"),
                    StudyPage(id: "p1", number: 2, image: URL(fileURLWithPath: "/x/p1.jpg"), draft: "")],
            slides: [AssemblyPage(id: "s0", number: 3, text: "Текст слайда")])
        let prompt = try PromptLibrary(root: URL(fileURLWithPath: "/nonexistent")).studyAssemblyPrompt(
            part: part, index: 1, of: 3, subject: "Алгебра", topic: "Матрицы")
        #expect(prompt.contains("--- Страница 1: ./p0.jpg ---\nЧерновая расшифровка"))
        #expect(prompt.contains("Черновик"))
        #expect(prompt.contains("--- Страница 2: ./p1.jpg ---"))
        #expect(prompt.contains("--- Слайд 3 ---\nТекст слайда"))
        #expect(prompt.contains("часть 2 из 3"))
        #expect(prompt.contains("Матрицы"))
    }

    @Test func modelIsDroppedOnAnotherEngine() {
        var request = AIRequest(prompt: "p", systemPrompt: "s")
        request.model = "opus"
        request.modelEngine = .claude
        let claude = EngineRouterTests.FakeEngine([], id: .claude)
        let codex = EngineRouterTests.FakeEngine([], id: .codex)
        #expect(EngineRouter.prepared(request, for: claude).model == "opus")
        #expect(EngineRouter.prepared(request, for: codex).model == nil)
    }
}

@Suite("Учебная сборка: вызов")
@MainActor
struct StudyAssemblyCenterTests {
    typealias Env = AssemblyCenterTests.Env
    typealias FakeEngine = EngineRouterTests.FakeEngine

    private func prepare(_ env: Env, photos: Int) throws {
        let paths = LecturePaths(folder: env.lecture.folder)
        for index in 0..<photos {
            let url = paths.notePhoto("p\(index)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0xFF, 0xD8]).write(to: url)
        }
    }

    private func center(_ env: Env, _ engine: FakeEngine, style: AssemblyStyle = .study, model: String = "opus") -> AssemblyCenter {
        let router = EngineRouter(primary: engine, fallback: nil, settings: .init())
        return AssemblyCenter(library: env.library, router: { router }, threshold: { 40_000 },
                              style: { style }, model: { model })
    }

    private func waitIdle(_ center: AssemblyCenter, _ id: UUID) async throws {
        for _ in 0..<250 {
            if !center.isRunning(id) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Сборка не закончилась за 5 с")
    }

    @Test func studyAssemblySendsPhotosWithChosenClaudeModel() async throws {
        let env = try Env(pages: ["Один", "Два"])
        try prepare(env, photos: 2)
        let engine = FakeEngine([.success("# Учебный конспект\n\nТекст")])
        let center = center(env, engine)
        center.assemble(env.lectureID)
        try await waitIdle(center, env.lectureID)

        #expect(center.errors[env.lectureID] == nil)
        let request = try #require(await engine.requests.first)
        #expect(request.images.map(\.lastPathComponent) == ["p0.jpg", "p1.jpg"])
        #expect(request.cloudOnly)
        #expect(request.model == "opus" && request.modelEngine == .claude)
        #expect(request.prompt.contains("./p0.jpg"))
        #expect(env.konspekt.read() == "# Учебный конспект\n\nТекст\n")
        let info = try #require(env.lecture.meta.konspekt)
        #expect(info.style == .study && info.parts == 1)
    }

    @Test func longStudyLectureIsMergedWithClaudeModel() async throws {
        let env = try Env(pages: (1...14).map { "Страница \($0)" })
        try prepare(env, photos: 14)
        let engine = FakeEngine([.success("часть 1"), .success("часть 2"), .success("итог")])
        let center = center(env, engine)
        center.assemble(env.lectureID)
        try await waitIdle(center, env.lectureID)
        let requests = await engine.requests
        #expect(requests.count == 3)
        #expect(requests.last?.images.isEmpty == true && requests.last?.model == "opus")
        // Склейка учебного конспекта использует свой промпт: он велит ничего не сокращать.
        #expect(requests.last?.prompt.contains("ВЕСЬ материал") == true)
        #expect(env.lecture.meta.konspekt?.parts == 2)
    }

    @Test func faithfulStyleStaysTextOnly() async throws {
        let env = try Env(pages: ["Один"])
        try prepare(env, photos: 1)
        let engine = FakeEngine([.success("Чистый текст")])
        let center = center(env, engine, style: .faithful)
        center.assemble(env.lectureID)
        try await waitIdle(center, env.lectureID)
        let request = try #require(await engine.requests.first)
        #expect(request.images.isEmpty && !request.cloudOnly && request.model == nil)
        #expect(env.lecture.meta.konspekt?.style == .faithful)
    }

    @Test func localOnlyFallsBackToFaithful() async throws {
        let env = try Env(pages: ["Один"])
        try prepare(env, photos: 1)
        let engine = FakeEngine([.success("Текст")], id: .ollama)
        let center = center(env, engine)
        center.assemble(env.lectureID)
        try await waitIdle(center, env.lectureID)
        #expect(center.errors[env.lectureID] == nil)
        #expect(await engine.requests.first?.images.isEmpty == true)
        #expect(env.lecture.meta.konspekt?.style == .faithful)
    }

    @Test func explicitStyleOverridesSetting() async throws {
        let env = try Env(pages: ["Один"])
        try prepare(env, photos: 1)
        let engine = FakeEngine([.success("Текст")])
        let center = center(env, engine, style: .faithful)
        center.assemble(env.lectureID, style: .study)
        try await waitIdle(center, env.lectureID)
        #expect(env.lecture.meta.konspekt?.style == .study)
    }
}

@Suite("Учебный конспект и «Дополнить»")
@MainActor
struct StudyKonspektEnrichmentTests {
    private let text = "# Тема\n\nТекст.\n\n> 💡 Пояснение: своими словами.\n\n```plot\n{\"x\": [0, 1], \"functions\": [{\"expr\": \"x\"}]}\n```\n"

    @Test func blocksAreKeptUnlessKonspektWasEnriched() {
        let plain = ArtifactInfo(createdAt: Date(), updatedAt: Date(), inputHash: "x")
        #expect(Enrichment.baseText(text, info: plain) == text)
        #expect(Enrichment.baseText(text, info: nil) == text)
        var enriched = plain
        enriched.enrichment = EnrichmentInfo(createdAt: Date())
        let base = Enrichment.baseText(text, info: enriched)
        #expect(!base.contains("💡") && !base.contains("```plot") && base.contains("Текст."))
    }
}

/// Живая учебная сборка настоящей лекции через Claude Code (по флагу, тратит лимит). Работает на копии папки лекции
/// `INKLING_LIVE_LECTURE`; результат пишется в `INKLING_LIVE_OUT`, модель — `INKLING_LIVE_MODEL` (по умолчанию opus).
@Suite("Учебная сборка: живой вызов", .enabled(if: ProcessInfo.processInfo.environment["INKLING_LIVE_CLAUDE"] == "1"))
@MainActor
struct StudyAssemblyLiveTests {
    @Test func assemblesRealLectureAsStudyKonspekt() async throws {
        let environment = ProcessInfo.processInfo.environment
        let source = URL(fileURLWithPath: try #require(environment["INKLING_LIVE_LECTURE"], "задайте INKLING_LIVE_LECTURE"))
        let dir = try TempDir()
        let root = dir.url.appendingPathComponent("Inkling")
        let copy = root.appendingPathComponent("Копия").appendingPathComponent("Лекция")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: copy)
        let library = Library(root: root, trasher: try FakeTrasher(bin: dir.url.appendingPathComponent("_bin")))
        library.open(root: root)
        let lecture = try #require(library.subjects.flatMap(\.lectures).first)

        let router = EngineRouter(primary: ClaudeCodeEngine(config: .init()), fallback: nil, settings: .init())
        let model = environment["INKLING_LIVE_MODEL"] ?? "opus"
        let center = AssemblyCenter(library: library, router: { router }, threshold: { 40_000 }, style: { .study }, model: { model })
        let started = Date()
        center.assemble(lecture.id)
        for _ in 0..<3000 where center.isRunning(lecture.id) { try await Task.sleep(for: .milliseconds(200)) }
        #expect(center.errors[lecture.id] == nil, "\(String(describing: center.errors[lecture.id]))")
        // Библиотека могла переименовать папку лекции по теме и дате: берём актуальный путь.
        let folder = try #require(library.lecture(id: lecture.id)).folder
        let result = try #require(KonspektStore(folder: folder).read())
        let info = library.lecture(id: lecture.id)?.meta.konspekt
        print("Время: \(Int(Date().timeIntervalSince(started))) с, модель \(info?.model ?? "?"), стиль \(String(describing: info?.style)), символов \(result.count)")
        if let out = environment["INKLING_LIVE_OUT"] { try result.write(toFile: out, atomically: true, encoding: .utf8) }
    }
}

@Suite("Учебная сборка с учебниками")
@MainActor
struct StudyAssemblyLiteratureTests {
    @Test func passagesGoIntoPromptAndReferencesIntoMeta() async throws {
        let env = try AssemblyCenterTests.Env(pages: ["Закон Гесса"])
        let paths = LecturePaths(folder: env.lecture.folder)
        try FileManager.default.createDirectory(at: paths.notePhoto("p0").deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xFF, 0xD8]).write(to: paths.notePhoto("p0"))
        let engine = EngineRouterTests.FakeEngine([.success("# Конспект")])
        let router = EngineRouter(primary: engine, fallback: nil, settings: .init())
        let center = AssemblyCenter(library: env.library, router: { router }, threshold: { 40_000 }, style: { .study }, model: { "" },
                                    literature: { subject, topic, texts in
                                        #expect(subject == "Высшая алгебра" && topic == "Матрицы" && texts == ["Закон Гесса"])
                                        return [LiteraturePassage(book: "Химия-1", page: 42, text: "Определение закона", score: -2)]
                                    })
        center.assemble(env.lectureID)
        for _ in 0..<250 where center.isRunning(env.lectureID) { try await Task.sleep(for: .milliseconds(20)) }
        let prompt = try #require(await engine.requests.first?.prompt)
        #expect(prompt.contains("[Химия-1, с. 42]\nОпределение закона"))
        #expect(prompt.contains("## Источники"))
        #expect(!prompt.contains("{учебники}"))
        #expect(env.lecture.meta.konspekt?.literature == ["Химия-1, с. 42"])
    }

    @Test func withoutTextbooksPromptHasNoPlaceholderAndNoMeta() async throws {
        let env = try AssemblyCenterTests.Env(pages: ["Один"])
        let paths = LecturePaths(folder: env.lecture.folder)
        try FileManager.default.createDirectory(at: paths.notePhoto("p0").deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xFF, 0xD8]).write(to: paths.notePhoto("p0"))
        let engine = EngineRouterTests.FakeEngine([.success("# Конспект")])
        let router = EngineRouter(primary: engine, fallback: nil, settings: .init())
        let center = AssemblyCenter(library: env.library, router: { router }, threshold: { 40_000 }, style: { .study })
        center.assemble(env.lectureID)
        for _ in 0..<250 where center.isRunning(env.lectureID) { try await Task.sleep(for: .milliseconds(20)) }
        let prompt = try #require(await engine.requests.first?.prompt)
        #expect(!prompt.contains("{учебники}") && !prompt.contains("Выдержки из учебников"))
        #expect(env.lecture.meta.konspekt?.literature == nil)
    }
}

@Suite("Вставки предметов для учебной сборки")
struct StudySubjectInsertTests {
    @Test func studyPromptUsesStudyInsertNotRecognitionInsert() throws {
        let dir = try TempDir()
        let prompts = PromptLibrary(root: dir.url)
        let subjects = prompts.folder.appendingPathComponent("subjects")
        try FileManager.default.createDirectory(at: subjects, withIntermediateDirectories: true)
        try "Переписывай как есть.".write(to: subjects.appendingPathComponent("Алгебра.md"), atomically: true, encoding: .utf8)
        try "Учебная вставка: определители.".write(to: subjects.appendingPathComponent("Алгебра — учебный.md"), atomically: true, encoding: .utf8)
        // В тестовой папке нет шаблона: берём его из бандла.
        let part = StudyPart(notes: [], slides: [AssemblyPage(id: "s", number: 1, text: "Слайд")])
        let prompt = try prompts.studyAssemblyPrompt(part: part, index: 0, of: 1, subject: "Алгебра", topic: "Т")
        #expect(prompt.contains("Учебная вставка: определители."))
        #expect(!prompt.contains("Переписывай как есть."))
        #expect(prompts.subjectStudyInsert("Нет такого").isEmpty)
    }

    @Test func bundledStudyInsertsExistForStarterSubjects() throws {
        let bundled = try #require(Bundle.main.url(forResource: "Prompts", withExtension: nil))
        for subject in LibraryStore.defaultSubjects + ["Дискретная математика"] {
            let url = bundled.appendingPathComponent("subjects").appendingPathComponent("\(subject) — учебный.md")
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.hasPrefix("Предмет:"), "\(subject)")
            #expect(text.contains("Оформление примеров решения типовых задач"), "\(subject)")
            #expect(!text.contains("переписывай как есть"), "\(subject)")
        }
    }
}

@Suite("Локальная проверка конспекта")
@MainActor
struct KonspektCheckTests {
    private let good = "# Конспект\n\n## Оглавление\n\n1. Раздел\n\n## 1. Раздел\n\nФормула $x^2 + 1$ и $$\\frac{a}{b}$$.\n\n## Примеры решения типовых задач\n\n## Источники\n"

    @Test func cleanKonspektHasNoProblems() {
        let check = KonspektChecker.check(good, study: true, expectSources: true)
        #expect(check.isClean, "\(check.summary)")
    }

    @Test func brokenFormulaAndMissingSectionsAreReported() {
        let text = "# Конспект\n\n## 1. Раздел\n\nЛомаем: $\\frac{a}{$ и нормальная $y$.\n\n```plot\nне json\n```\n"
        let check = KonspektChecker.check(text, study: true, expectSources: true)
        #expect(check.brokenFormulas.count == 1 && check.brokenFormulas[0].tex == "\\frac{a}{")
        #expect(!check.brokenFormulas[0].message.isEmpty)
        #expect(check.diagramErrors == 1)
        #expect(check.missingStructure == ["«Оглавление»", "раздела примеров", "«Источники»"])
        #expect(check.summary.contains("формул с ошибкой: 1") && check.summary.contains("не отрисовано рисунков: 1"))
        // Точная сборка структуру не проверяет, формулы проверяет.
        #expect(KonspektChecker.check(text, study: false, expectSources: false).missingStructure.isEmpty)
    }

    @Test func formulasInsideCodeBlocksAreNotChecked() {
        let check = KonspektChecker.check("```\n$\\frac{a}{$\n```\n", study: false, expectSources: false)
        #expect(check.brokenFormulas.isEmpty)
    }

    @Test func fixAppliesOnlyFormulasThatNowRender() async throws {
        let env = try AssemblyCenterTests.Env(pages: ["x"])
        let store = KonspektStore(folder: env.lecture.folder)
        let original = "Текст $\\frac{a}{$ и ещё $\\sqrt{$ конец.\n"
        try store.write(original, previous: nil)
        env.library.mutate(env.lectureID) {
            $0.konspekt = ArtifactInfo(createdAt: Date(), updatedAt: Date(), inputHash: "x")
        }
        let engine = EngineRouterTests.FakeEngine([.success(#"{"fixes":[{"id":1,"tex":"\\frac{a}{b}"},{"id":2,"tex":"\\sqrt{"}]}"#)])
        let router = EngineRouter(primary: engine, fallback: nil, settings: .init())
        let center = KonspektCheckCenter(library: env.library, router: { router })
        center.refresh(env.lecture)
        for _ in 0..<250 where center.checks[env.lectureID] == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(center.checks[env.lectureID]?.brokenFormulas.count == 2)
        center.fixFormulas(env.lectureID)
        for _ in 0..<250 where center.isFixing(env.lectureID) || center.lastFixed[env.lectureID] == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        // Первая формула исправлена, вторая осталась сломанной: исправление не прошло проверку и не применено.
        #expect(store.read() == "Текст $\\frac{a}{b}$ и ещё $\\sqrt{$ конец.\n")
        #expect(center.lastFixed[env.lectureID] == 1)
        #expect(store.history.entries().count == 1)
    }
}
