import Foundation
import JavaScriptCore
import Testing
@testable import Inkling

@Suite("Рендер Markdown и формул")
struct RenderJSTests {
    /// Тот же набор скриптов, что в notes.html, в JavaScriptCore (без DOM).
    let context: JSContext = {
        let context = JSContext()!
        context.exceptionHandler = { _, exception in Issue.record("JS: \(exception?.toString() ?? "?")") }
        // В WebKit atob есть; в голом JavaScriptCore — нет.
        let atob: @convention(block) (String) -> String = { base64 in
            String(data: Data(base64Encoded: base64) ?? Data(), encoding: .isoLatin1) ?? ""
        }
        context.setObject(atob, forKeyedSubscript: "atob" as NSString)
        context.evaluateScript("var self = this; var globalThis = this;")
        let web = NotesWebView.webFolder!
        for file in ["vendor/katex/katex.min.js", "vendor/katex/contrib/mhchem.min.js",
                     "vendor/markdown-it/markdown-it.umd.min.js", "render.js"] {
            context.evaluateScript(try! String(contentsOf: web.appendingPathComponent(file), encoding: .utf8),
                                   withSourceURL: web.appendingPathComponent(file))
        }
        return context
    }()

    private func html(_ markdown: String) -> String {
        context.objectForKeyedSubscript("InklingRender")!.invokeMethod("toHTML", withArguments: [markdown])!.toString()
    }

    @Test func bundleContainsWebAssets() throws {
        let web = try #require(NotesWebView.webFolder)
        for file in ["notes.html", "notes.css", "render.js", "vendor/katex/katex.min.css",
                     "vendor/katex/fonts/KaTeX_Main-Regular.woff2", "vendor/VERSIONS.md"] {
            #expect(FileManager.default.fileExists(atPath: web.appendingPathComponent(file).path), "\(file)")
        }
    }

    @Test func markdownAndInlineMath() {
        let out = html("# Тема\n\nФормула $a_1 * b_2$ в тексте.")
        #expect(out.contains("<h1>Тема</h1>"))
        #expect(out.contains("class=\"katex\""))
        #expect(!out.contains("<em>"), "Подчёркивания и звёздочки внутри формулы не должны стать курсивом")
    }

    @Test func displayMathIsBlock() {
        let out = html("$$\\int_0^1 x\\,dx = \\frac{1}{2}$$")
        #expect(out.contains("class=\"math-display\""))
        #expect(out.contains("katex-display"))
        #expect(!out.contains("<p><div"))
    }

    @Test func mhchemWorks() {
        let out = html("Реакция $\\ce{2H2 + O2 -> 2H2O}$.")
        #expect(out.contains("class=\"katex\""))
        #expect(!out.contains("katex-error"))
    }

    @Test func brokenFormulaShowsSourceInRed() {
        let out = html("До $\\frac{1}{$ после, и $x^2$ рядом.")
        #expect(out.contains("katex-error"))
        #expect(out.contains("после"))
        #expect(out.components(separatedBy: "class=\"katex\"").count >= 2, "Соседняя формула всё равно отрисована")
    }

    @Test func dollarsInCodeAndPricesStayText() {
        let out = html("Цена $5 и $10.\n\nКод `$x$`.\n\n```\n$$ y $$\n```")
        #expect(!out.contains("katex"))
        #expect(out.contains("$5 и $10"))
        #expect(out.contains("<code>$x$</code>"))
        #expect(out.contains("$$ y $$"))
    }

    @Test func escapedDollar() {
        #expect(!html("Стоит \\$3 и \\$4").contains("katex"))
    }

    @Test func calloutsAndIllegible() {
        let out = html("> ⚠️ Возможно, ошибка: знак.\n\n> 📎 Из слайдов: таблица.\n\nТекст [неразборчиво] тут.")
        #expect(out.contains("<blockquote class=\"callout warn\">"))
        #expect(out.contains("<blockquote class=\"callout slides\">"))
        #expect(out.contains("<mark class=\"illegible\">[неразборчиво]</mark>"))
    }

    @Test func htmlIsEscaped() {
        #expect(html("<script>alert(1)</script>").contains("&lt;script&gt;"))
    }
}

@Suite("Планировщик сборки")
struct AssemblyPlannerTests {
    private func pages(_ sizes: [Int], prefix: String = "n") -> [AssemblyPage] {
        sizes.enumerated().map { AssemblyPage(id: "\(prefix)\($0.offset + 1)", number: $0.offset + 1,
                                              text: String(repeating: "а", count: $0.element)) }
    }

    @Test func modes() {
        #expect(AssemblyInput(notes: pages([10])).mode == .notesOnly)
        #expect(AssemblyInput(notes: pages([10]), slides: pages([5], prefix: "s")).mode == .notesWithSlides)
        #expect(AssemblyInput(slides: pages([5], prefix: "s")).mode == .slidesOnly)
        #expect(AssemblyInput().mode == nil)
        #expect(AssemblyPlanner.plan(AssemblyInput(), threshold: 40_000) == nil)
    }

    @Test func shortLectureIsOneCall() {
        let input = AssemblyInput(notes: pages([5000, 5000]), slides: pages([1000], prefix: "s"))
        let plan = AssemblyPlanner.plan(input, threshold: 40_000)!
        #expect(plan.parts.count == 1 && !plan.needsMerge && plan.calls == 1)
        #expect(plan.parts[0].slides.count == 1)
    }

    @Test func chunksOverlapByOnePage() {
        let chunks = AssemblyPlanner.chunk(pages([4000, 4000, 4000, 4000, 4000, 4000]), limit: 10_000)
        #expect(chunks.map { $0.map(\.number) } == [[1, 2], [2, 3], [3, 4], [4, 5], [5, 6]])
    }

    @Test func hugePageGoesAlone() {
        let chunks = AssemblyPlanner.chunk(pages([1000, 50_000, 1000]), limit: 10_000)
        #expect(chunks.map { $0.map(\.number) } == [[1], [2], [3]])
    }

    @Test func notesOnlyLongLecture() {
        let plan = AssemblyPlanner.plan(AssemblyInput(notes: pages(Array(repeating: 9000, count: 10))), threshold: 40_000)!
        #expect(plan.needsMerge)
        #expect(plan.calls == plan.parts.count + 1)
        #expect(plan.parts.first?.notes.first?.number == 1)
        #expect(plan.parts.last?.notes.last?.number == 10)
        for (a, b) in zip(plan.parts, plan.parts.dropFirst()) {
            #expect(a.notes.last?.id == b.notes.first?.id, "Соседние части перекрываются на одну страницу")
        }
    }

    @Test func slidesSliceIsProportionalWithOverlap() {
        let slides = pages(Array(repeating: 100, count: 60), prefix: "s")
        let first = AssemblyPlanner.slice(slides, part: 0, of: 3).map(\.number)
        let middle = AssemblyPlanner.slice(slides, part: 1, of: 3).map(\.number)
        let last = AssemblyPlanner.slice(slides, part: 2, of: 3).map(\.number)
        #expect(first == Array(1...22))
        #expect(middle == Array(19...42))
        #expect(last == Array(39...60))
    }

    @Test func notesWithSlidesPartsStayUnderThreshold() {
        let input = AssemblyInput(notes: pages(Array(repeating: 6000, count: 12)),
                                  slides: pages(Array(repeating: 600, count: 50), prefix: "s"))
        let plan = AssemblyPlanner.plan(input, threshold: 40_000)!
        #expect(plan.mode == .notesWithSlides && plan.needsMerge)
        for part in plan.parts {
            let size = (part.notes + part.slides).reduce(0) { $0 + $1.text.count }
            #expect(size <= 40_000 + 4 * 600, "Часть \(size) символов")
            #expect(!part.slides.isEmpty)
        }
        #expect(plan.parts.first?.slides.first?.number == 1)
        #expect(plan.parts.last?.slides.last?.number == 50)
    }

    @Test func slidesOnlyLongLecture() {
        let plan = AssemblyPlanner.plan(AssemblyInput(slides: pages(Array(repeating: 2000, count: 40), prefix: "s")),
                                        threshold: 40_000)!
        #expect(plan.mode == .slidesOnly && plan.needsMerge)
        #expect(plan.parts.allSatisfy { $0.notes.isEmpty })
    }

    @Test func timeoutGrowsWithVolume() {
        #expect(AssemblyPlanner.timeout(chars: 1000) == 180)
        #expect(AssemblyPlanner.timeout(chars: 40_000) == 520)
        #expect(AssemblyPlanner.timeout(chars: 10_000_000) == 1800)
    }

    @Test func unwrapFencedAnswer() {
        #expect(MarkdownCleanup.unwrap("```markdown\n# Тема\n\nтекст\n```") == "# Тема\n\nтекст")
        #expect(MarkdownCleanup.unwrap("```\n# Тема\n```") == "# Тема")
        #expect(MarkdownCleanup.unwrap("# Тема\n\n```\nкод\n```") == "# Тема\n\n```\nкод\n```")
        #expect(MarkdownCleanup.unwrap("  # Тема  \n") == "# Тема")
    }
}

@Suite("Входные данные и промпты сборки")
struct AssemblyInputTests {
    private func lecture() throws -> (TempDir, LectureMeta, PageTextStore) {
        let dir = try TempDir()
        var meta = LectureMeta(subject: "Высшая алгебра", topic: "Матрицы", date: .d("2026-10-14"))
        meta.notes = ["a", "b", "c"].map { NotePage(id: $0, source: .image(file: "\($0).jpg"), crop: .original, addedAt: Date()) }
        meta.slides = [
            SlidePage(id: "s1", source: .pdfPage(file: "d.pdf", index: 0), heuristicNeedsImage: false, addedAt: Date()),
            SlidePage(id: "s2", source: .pdfPage(file: "d.pdf", index: 1), heuristicNeedsImage: false, excluded: true, addedAt: Date()),
            SlidePage(id: "s3", source: .pdfPage(file: "d.pdf", index: 2), heuristicNeedsImage: true, addedAt: Date()),
        ]
        let store = PageTextStore(paths: LecturePaths(folder: dir.url))
        try store.write("Страница A", id: "a", in: .notes, previous: nil)
        try store.write("Страница C", id: "c", in: .notes, previous: nil)
        for id in ["s1", "s2", "s3"] { try store.write("Слайд \(id)", id: id, in: .slides, previous: nil) }
        return (dir, meta, store)
    }

    @Test func collectSkipsUnrecognizedAndExcluded() throws {
        let (dir, meta, store) = try lecture()
        defer { withExtendedLifetime(dir) {} }
        let input = AssemblyInput.collect(meta: meta, texts: store)
        #expect(input.notes.map(\.number) == [1, 3])
        #expect(input.unrecognizedNotes == 1)
        #expect(input.slides.map(\.id) == ["s1"])
        #expect(input.unrecognizedSlides == 1)
        #expect(input.mode == .notesWithSlides)
    }

    @Test func hashTracksTextAndOrder() throws {
        let (dir, meta, store) = try lecture()
        defer { withExtendedLifetime(dir) {} }
        let base = AssemblyInput.collect(meta: meta, texts: store).hash
        #expect(AssemblyInput.collect(meta: meta, texts: store).hash == base)

        try store.write("Страница A (правка)", id: "a", in: .notes, previous: nil)
        let edited = AssemblyInput.collect(meta: meta, texts: store).hash
        #expect(edited != base)

        var reordered = meta
        reordered.movePages(["c"], before: "a", in: .notes)
        #expect(AssemblyInput.collect(meta: reordered, texts: store).hash != edited)

        var excluded = meta
        excluded.setSlideExcluded(true, for: "s1")
        #expect(AssemblyInput.collect(meta: excluded, texts: store).hash != edited)
    }

    @Test func promptsForEachMode() throws {
        let dir = try TempDir()
        let prompts = PromptLibrary(root: dir.url)
        try prompts.installMissingDefaults()
        let notes = [AssemblyPage(id: "a", number: 1, text: "Текст A"), AssemblyPage(id: "b", number: 2, text: "Текст B")]
        let slides = [AssemblyPage(id: "s", number: 7, text: "Слайд семь")]

        let plain = try prompts.assemblyPrompt(mode: .notesOnly, part: AssemblyPart(notes: notes, slides: []),
                                               index: 0, of: 1, subject: "Высшая алгебра", topic: "Матрицы")
        #expect(plain.contains("--- Страница 1 ---\nТекст A\n\n--- Страница 2 ---\nТекст B"))
        #expect(plain.contains("> ⚠️ Возможно, ошибка"))
        #expect(plain.contains("pmatrix"))
        #expect(!plain.contains("Это часть"))

        let withSlides = try prompts.assemblyPrompt(mode: .notesWithSlides, part: AssemblyPart(notes: notes, slides: slides),
                                                    index: 1, of: 3, subject: "Высшая алгебра", topic: "Матрицы")
        #expect(withSlides.contains("--- Слайд 7 ---\nСлайд семь"))
        #expect(withSlides.contains("📎 Из слайдов"))
        #expect(withSlides.contains("Это часть 2 из 3 длинной лекции (страницы 1–2)"))
        #expect(!withSlides.contains("{слайды}"))

        let slidesOnly = try prompts.assemblyPrompt(mode: .slidesOnly, part: AssemblyPart(notes: [], slides: slides),
                                                    index: 0, of: 1, subject: "Физика", topic: "Кинематика")
        #expect(slidesOnly.contains("--- Слайд 7 ---"))
        #expect(!slidesOnly.contains("--- Страница"))

        let merge = try prompts.mergePrompt(parts: ["# Часть один", "# Часть два"], subject: "Х", topic: "Т")
        #expect(merge.contains("=== Часть 1 ===\n# Часть один\n\n=== Часть 2 ===\n# Часть два"))
    }
}

@Suite("Сборка конспекта")
@MainActor
struct AssemblyCenterTests {
    typealias FakeEngine = EngineRouterTests.FakeEngine

    @MainActor
    final class Env {
        let dir: TempDir
        let library: Library
        let lectureID: UUID

        init(pages: [String]) throws {
            dir = try TempDir()
            library = Library(root: dir.url.appendingPathComponent("Inkling"),
                              trasher: try FakeTrasher(bin: dir.url.appendingPathComponent("_bin")))
            library.open(root: library.root)
            #expect(library.createLecture(subject: "Высшая алгебра", topic: "Матрицы", date: .d("2026-10-14")))
            lectureID = try #require(library.selection)
            let ids = pages.indices.map { "p\($0)" }
            library.mutate(lectureID) { meta in
                meta.notes = ids.map { NotePage(id: $0, source: .image(file: "\($0).jpg"), crop: .original, addedAt: Date(),
                                                text: PageText(origin: .model, updatedAt: Date())) }
            }
            let store = PageTextStore(paths: LecturePaths(folder: lecture.folder))
            for (id, text) in zip(ids, pages) { try store.write(text, id: id, in: .notes, previous: nil) }
        }

        var lecture: LectureRecord { library.lecture(id: lectureID)! }
        var konspekt: KonspektStore { KonspektStore(folder: lecture.folder) }

        func center(_ engine: FakeEngine, threshold: Int = 40_000) -> AssemblyCenter {
            let router = EngineRouter(primary: engine, fallback: nil, settings: .init())
            return AssemblyCenter(library: library, router: { router }, threshold: { threshold })
        }
    }

    private func waitIdle(_ center: AssemblyCenter, _ id: UUID) async throws {
        for _ in 0..<250 {
            if !center.isRunning(id) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Сборка не закончилась за 5 с")
    }

    @Test func singleCallWritesKonspektAndMeta() async throws {
        let env = try Env(pages: ["Страница один", "Страница два"])
        let engine = FakeEngine([.success("```markdown\n# Матрицы\n\nКонспект\n```")])
        let center = env.center(engine)
        #expect(center.readiness(env.lecture).plan?.calls == 1)
        center.assemble(env.lectureID)
        #expect(center.isRunning(env.lectureID))
        try await waitIdle(center, env.lectureID)

        #expect(env.konspekt.read() == "# Матрицы\n\nКонспект\n")
        let info = try #require(env.lecture.meta.konspekt)
        #expect(info.mode == .notesOnly && info.parts == 1 && info.model == "fake" && !info.manuallyEdited)
        #expect(!center.readiness(env.lecture).isStale)
        let prompt = try #require(await engine.requests.first?.prompt)
        #expect(prompt.contains("--- Страница 2 ---\nСтраница два"))
        #expect(await engine.requests.first?.images.isEmpty == true)
    }

    @Test func longLectureIsChunkedAndMerged() async throws {
        let env = try Env(pages: Array(repeating: String(repeating: "x", count: 4000), count: 5))
        let engine = FakeEngine([], delay: .milliseconds(10))
        let center = env.center(engine, threshold: 9000)
        let plan = try #require(center.readiness(env.lecture).plan)
        #expect(plan.needsMerge)
        center.assemble(env.lectureID)
        try await waitIdle(center, env.lectureID)

        let requests = await engine.requests
        #expect(requests.count == plan.calls)
        let merge = try #require(requests.last)
        #expect(merge.prompt.contains("=== Часть 1 ===\nok"))
        #expect(merge.prompt.contains("=== Часть \(plan.parts.count) ===\nok"))
        #expect(requests.dropLast().allSatisfy { $0.prompt.contains("Это часть") })
        #expect(env.lecture.meta.konspekt?.parts == plan.parts.count)
    }

    @Test func failureKeepsPreviousKonspekt() async throws {
        let env = try Env(pages: ["Страница"])
        let first = env.center(FakeEngine([.success("Первая версия")]))
        first.assemble(env.lectureID)
        try await waitIdle(first, env.lectureID)

        let failing = env.center(FakeEngine([.failure(.notAuthenticated("Not logged in"))]))
        failing.assemble(env.lectureID)
        try await waitIdle(failing, env.lectureID)
        #expect(failing.errors[env.lectureID] == .notAuthenticated("Not logged in"))
        #expect(env.konspekt.read() == "Первая версия\n")
    }

    @Test func rebuildKeepsHistoryAndDetectsStaleness() async throws {
        let env = try Env(pages: ["Страница"])
        let center = env.center(FakeEngine([.success("Версия 1"), .success("Версия 2")]))
        center.assemble(env.lectureID)
        try await waitIdle(center, env.lectureID)

        env.library.saveEditedText("Страница (правка)", pageID: "p0", lectureID: env.lectureID)
        #expect(center.readiness(env.lecture).isStale)

        center.assemble(env.lectureID)
        try await waitIdle(center, env.lectureID)
        #expect(env.konspekt.read() == "Версия 2\n")
        #expect(!center.readiness(env.lecture).isStale)
        let history = env.konspekt.history.entries()
        #expect(history.count == 1)
        #expect(try String(contentsOf: history[0].file, encoding: .utf8) == "Версия 1\n")
        #expect(history[0].info(ArtifactInfo.self)?.model == "fake")
    }

    @Test func manualEditAndRestore() async throws {
        let env = try Env(pages: ["Страница"])
        let center = env.center(FakeEngine([.success("Модель")]))
        center.assemble(env.lectureID)
        try await waitIdle(center, env.lectureID)

        env.library.saveKonspektEdit("Правка 1\n", lectureID: env.lectureID)
        env.library.saveKonspektEdit("Правка 2\n", lectureID: env.lectureID)
        #expect(env.lecture.meta.konspekt?.manuallyEdited == true)
        let history = env.konspekt.history.entries()
        #expect(history.count == 1, "В историю попадает только версия модели до первой правки")

        env.library.restoreKonspekt(history[0], lectureID: env.lectureID)
        #expect(env.konspekt.read() == "Модель\n")
        #expect(env.lecture.meta.konspekt?.manuallyEdited == false)
        #expect(env.konspekt.history.entries().count == 2)
    }

    @Test func cancelLeavesNothing() async throws {
        let env = try Env(pages: ["Страница"])
        let center = env.center(FakeEngine([], delay: .seconds(5)))
        center.assemble(env.lectureID)
        try await Task.sleep(for: .milliseconds(100))
        center.cancel(env.lectureID)
        try await waitIdle(center, env.lectureID)
        #expect(center.errors[env.lectureID] == nil)
        #expect(env.konspekt.read() == nil)
        #expect(env.lecture.meta.konspekt == nil)
    }

    @Test func nothingToAssemble() throws {
        let env = try Env(pages: [])
        let center = env.center(FakeEngine([]))
        #expect(center.readiness(env.lecture).plan == nil)
        center.assemble(env.lectureID)
        #expect(!center.isRunning(env.lectureID))
        #expect(center.errors[env.lectureID] != nil)
    }
}

/// Живая сборка с настоящим Claude Code (по флагу).
@Suite("Сборка: живой вызов", .enabled(if: ProcessInfo.processInfo.environment["INKLING_LIVE_CLAUDE"] == "1"))
@MainActor
struct AssemblyLiveTests {
    @Test func assemblesTwoChemistryPages() async throws {
        let env = try AssemblyCenterTests.Env(pages: [
            "Тема: ОВР\n1. Окислитель принимает электроны,",
            "восстановитель отдаёт.\nПример: $\\ce{2H2 + O2 -> 2H2O}$\nСтепень окисления O в H2O равна +2.",
        ])
        let router = EngineRouter(primary: ClaudeCodeEngine(config: .init()), fallback: nil, settings: .init())
        let center = AssemblyCenter(library: env.library, router: { router }, threshold: { 40_000 })
        center.assemble(env.lectureID)
        for _ in 0..<900 where center.isRunning(env.lectureID) { try await Task.sleep(for: .milliseconds(200)) }
        #expect(center.errors[env.lectureID] == nil)
        let text = try #require(env.konspekt.read())
        print("Конспект:\n\(text)")
        #expect(text.contains(#"\ce{"#))
        #expect(text.contains("⚠️"), "Ошибку «+2» модель должна пометить")
        #expect(!text.contains("--- Страница"))
    }
}

@Suite("Подстановки в промптах")
struct PromptRenderTests {
    @Test func substitutedTextIsNotExpandedAgain() {
        let out = PromptLibrary.render("Тема: {тема}\n{конспект}\n{нет}",
                                       values: ["тема": "Матрицы", "конспект": "см. {тема} и {предмет}"])
        #expect(out == "Тема: Матрицы\nсм. {тема} и {предмет}\n{нет}")
    }
}
