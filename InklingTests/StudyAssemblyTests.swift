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

    @Test func longLectureSplitsByPhotosWithOnePageOverlap() throws {
        let plan = try #require(StudyAssemblyPlanner.plan(meta: meta(pages: 14), input: input(), paths: paths, fileExists: { _ in true }))
        #expect(plan.parts.map { $0.notes.map(\.number) } == [Array(1...6), Array(6...11), Array(11...14)])
        #expect(plan.needsMerge && plan.calls == 4 && plan.imageCount == 16)
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
        let env = try Env(pages: (1...8).map { "Страница \($0)" })
        try prepare(env, photos: 8)
        let engine = FakeEngine([.success("часть 1"), .success("часть 2"), .success("итог")])
        let center = center(env, engine)
        center.assemble(env.lectureID)
        try await waitIdle(center, env.lectureID)
        let requests = await engine.requests
        #expect(requests.count == 3)
        #expect(requests.last?.images.isEmpty == true && requests.last?.model == "opus")
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

    @Test func enrichmentRefusesStudyKonspektAndKeepsFile() async throws {
        let env = try AssemblyCenterTests.Env(pages: ["Один"])
        try KonspektStore(folder: env.lecture.folder).write(text, previous: nil)
        env.library.mutate(env.lectureID) {
            var info = ArtifactInfo(createdAt: Date(), updatedAt: Date(), inputHash: "x")
            info.style = .study
            $0.konspekt = info
        }
        let engine = EngineRouterTests.FakeEngine([.success("не должен")])
        let router = EngineRouter(primary: engine, fallback: nil, settings: .init())
        let center = EnrichmentCenter(library: env.library, router: { router })
        center.enrich(env.lectureID)
        #expect(!center.isRunning(env.lectureID))
        #expect(center.errors[env.lectureID] != nil)
        #expect(await engine.calls == 0)
        #expect(KonspektStore(folder: env.lecture.folder).read() == text)
    }
}
