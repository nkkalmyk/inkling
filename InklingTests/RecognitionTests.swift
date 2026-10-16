import Foundation
import Testing
@testable import Inkling

@Suite("Промпты")
struct PromptLibraryTests {
    @Test func bundledDefaultsArePresent() throws {
        let bundled = try #require(PromptLibrary(root: URL(fileURLWithPath: "/tmp")).bundled)
        for name in ["recognize.md", "recognize-slide.md", "subjects/Общая и неорганическая химия.md",
                     "subjects/Математический анализ.md", "subjects/Высшая алгебра.md", "subjects/_образцы/Физика.md"] {
            #expect(FileManager.default.fileExists(atPath: bundled.appendingPathComponent(name).path), "\(name)")
        }
    }

    @Test func installCopiesOnlyMissingFiles() throws {
        let dir = try TempDir()
        let prompts = PromptLibrary(root: dir.url)
        try FileManager.default.createDirectory(at: prompts.folder, withIntermediateDirectories: true)
        try "мой промпт".write(to: prompts.folder.appendingPathComponent("recognize.md"), atomically: true, encoding: .utf8)
        try prompts.installMissingDefaults()
        #expect(try prompts.template("recognize.md") == "мой промпт")
        #expect(try prompts.template("recognize-slide.md").contains("слайд"))
        #expect(prompts.subjectInsert("Высшая алгебра").contains("pmatrix"))
    }

    @Test func resetKeepsUserVersions() throws {
        let dir = try TempDir()
        let prompts = PromptLibrary(root: dir.url)
        try prompts.installMissingDefaults()
        #expect(try prompts.resetToDefaults() == nil)

        try "правка".write(to: prompts.folder.appendingPathComponent("recognize.md"), atomically: true, encoding: .utf8)
        let backup = try #require(try prompts.resetToDefaults())
        #expect(try String(contentsOf: backup.appendingPathComponent("recognize.md"), encoding: .utf8) == "правка")
        #expect(try prompts.template("recognize.md").contains("[неразборчиво]"))
    }

    @Test func missingTemplateFallsBackToBundle() throws {
        let dir = try TempDir()
        #expect(try PromptLibrary(root: dir.url).template("recognize.md").contains("{предмет}"))
        #expect(throws: PromptError.self) { try PromptLibrary(root: dir.url).template("нет.md") }
    }

    @Test func renderSubstitutesKnownKeys() {
        let text = PromptLibrary.render("Предмет «{предмет}», тема {тема}. {вставка_предмета}\n{неизвестно}",
                                        values: ["предмет": "Химия", "тема": "ОВР", "вставка_предмета": ""])
        #expect(text == "Предмет «Химия», тема ОВР. \n{неизвестно}")
    }

    @Test func recognitionPromptIncludesInsertAndImage() throws {
        let dir = try TempDir()
        let prompts = PromptLibrary(root: dir.url)
        try prompts.installMissingDefaults()
        let prompt = try prompts.recognitionPrompt(section: .notes, subject: "Общая и неорганическая химия",
                                                   topic: "ОВР", imageName: "abc.jpg")
        #expect(prompt.contains("по предмету «Общая и неорганическая химия»"))
        #expect(prompt.contains("Правила для химии"))
        #expect(prompt.hasSuffix("Изображение: ./abc.jpg"))
        #expect(!prompt.contains("{предмет}") && !prompt.contains("{вставка_предмета}"))

        let unknown = try prompts.recognitionPrompt(section: .slides, subject: "Философия", topic: "Кант", imageName: "s.jpg")
        #expect(unknown.contains("тема лекции «Кант»"))
        #expect(!unknown.contains("{вставка_предмета}"))
    }
}

@Suite("История и тексты страниц")
struct PageTextStoreTests {
    @Test func writeKeepsPreviousVersionInHistory() throws {
        let dir = try TempDir()
        let store = PageTextStore(paths: LecturePaths(folder: dir.url))
        let first = PageText(origin: .model, engine: .claude, model: "m1", updatedAt: Date(timeIntervalSince1970: 0))
        try store.write("версия 1", id: "p", in: .notes, previous: nil, now: Date(timeIntervalSince1970: 100))
        #expect(store.history("p", in: .notes).entries().isEmpty)

        try store.write("версия 2", id: "p", in: .notes, previous: first, now: Date(timeIntervalSince1970: 200))
        try store.write("версия 2", id: "p", in: .notes, previous: first, now: Date(timeIntervalSince1970: 300))
        let entries = store.history("p", in: .notes).entries()
        #expect(entries.count == 1)
        #expect(try String(contentsOf: entries[0].file, encoding: .utf8) == "версия 1")
        #expect(entries[0].info(PageText.self) == first)
        #expect(entries[0].date == Date(timeIntervalSince1970: 200))
        #expect(store.read("p", in: .notes) == "версия 2")
    }

    @Test func intermediateManualSavesSkipHistory() throws {
        let dir = try TempDir()
        let store = PageTextStore(paths: LecturePaths(folder: dir.url))
        try store.write("a", id: "p", in: .slides, previous: nil)
        try store.write("ab", id: "p", in: .slides, previous: nil, saveHistory: false)
        #expect(store.history("p", in: .slides).entries().isEmpty)
    }

    @Test func restoreSavesCurrentFirst() throws {
        let dir = try TempDir()
        let store = PageTextStore(paths: LecturePaths(folder: dir.url))
        let modelInfo = PageText(origin: .model, engine: .claude, model: "m", updatedAt: Date(timeIntervalSince1970: 0))
        try store.write("модель", id: "p", in: .notes, previous: nil, now: Date(timeIntervalSince1970: 1))
        try store.write("правка", id: "p", in: .notes, previous: modelInfo, now: Date(timeIntervalSince1970: 2))
        let old = try #require(store.history("p", in: .notes).entries().first)
        let restored = try store.restore(old, id: "p", in: .notes, current: nil, now: Date(timeIntervalSince1970: 3))
        #expect(restored == modelInfo)
        #expect(store.read("p", in: .notes) == "модель")
        let entries = store.history("p", in: .notes).entries()
        #expect(entries.count == 2)
        #expect(try String(contentsOf: entries[0].file, encoding: .utf8) == "правка")
    }

    @Test func stampsSortAndParse() {
        let date = Date(timeIntervalSince1970: 1_800_000_000.123)
        let stamp = HistoryStore.stamp(date)
        #expect(!stamp.contains(":"))
        #expect(abs(HistoryStore.date(fromStamp: stamp)!.timeIntervalSince(date)) < 0.001)
        #expect(HistoryStore.stamp(date) < HistoryStore.stamp(date.addingTimeInterval(0.002)))
    }

    @Test func staleTextAfterPhotoChange() {
        var page = NotePage(id: "p", source: .image(file: "p.jpg"), crop: .original, addedAt: Date(), imageHash: "A")
        #expect(!page.textIsStale)
        page.text = PageText(origin: .model, updatedAt: Date(), imageHash: "A")
        #expect(!page.textIsStale)
        page.imageHash = "B"
        #expect(page.textIsStale)
    }

    @Test func switchingSlideToTextLayerKeepsModelTextInHistory() throws {
        let dir = try TempDir()
        let lecture = dir.url.appendingPathComponent("lecture")
        let importer = SourceImporter(paths: LecturePaths(folder: lecture))
        let pdf = Fixtures.pdf(pages: [nil], to: dir.url.appendingPathComponent("d.pdf"))
        var slide = try #require(importer.importFiles([pdf], into: .slides).slides.first)
        #expect(slide.text == nil && slide.needsRecognition)

        let store = PageTextStore(paths: LecturePaths(folder: lecture))
        try store.write("распознано моделью", id: slide.id, in: .slides, previous: nil)
        slide.text = PageText(origin: .model, engine: .claude, model: "m", updatedAt: Date())
        #expect(!slide.needsRecognition)

        slide.mode = .textLayer
        let info = try importer.syncSlideFiles(slide)
        #expect(info?.origin == .textLayer)
        #expect(store.history(slide.id, in: .slides).entries().first?.info(PageText.self)?.origin == .model)
    }
}

@Suite("Распознавание")
@MainActor
struct RecognitionCenterTests {
    typealias FakeEngine = EngineRouterTests.FakeEngine

    @MainActor
    final class Env {
        let dir: TempDir
        let library: Library
        let lectureID: UUID
        var pages: [String] = []

        init(photos: Int, subject: String = "Общая и неорганическая химия") throws {
            dir = try TempDir()
            library = Library(root: dir.url.appendingPathComponent("Inkling"),
                              trasher: try FakeTrasher(bin: dir.url.appendingPathComponent("_bin")))
            library.open(root: library.root)
            #expect(library.createLecture(subject: subject, topic: "ОВР", date: .d("2026-10-14")))
            lectureID = try #require(library.selection)
            let lecture = try #require(library.lecture(id: lectureID))
            let urls = (0..<photos).map { i in
                Fixtures.write(Fixtures.halfRed(), to: dir.url.appendingPathComponent("p\(i).jpg"),
                               dateTimeOriginal: "2026:10:14 09:0\(i):00")
            }
            let result = SourceImporter(paths: LecturePaths(folder: lecture.folder)).importFiles(urls, into: .notes)
            library.mutate(lectureID) { $0.appendImported(result) }
            pages = result.notes.map(\.id)
        }

        var lecture: LectureRecord { library.lecture(id: lectureID)! }
        var textStore: PageTextStore { PageTextStore(paths: LecturePaths(folder: lecture.folder)) }

        func center(_ engine: FakeEngine, parallel: Int = 2) -> RecognitionCenter {
            let router = EngineRouter(primary: engine, fallback: nil, settings: .init(maxParallel: parallel))
            let center = RecognitionCenter(library: library, router: { router }, timeout: { 30 }, maxParallel: { parallel })
            library.recognition = center
            return center
        }
    }

    private func waitIdle(_ center: RecognitionCenter, _ lectureID: UUID) async throws {
        for _ in 0..<250 {
            if !center.isBusy(lectureID) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Распознавание не закончилось за 5 с")
    }

    @Test func recognizesPagesAndRecordsProvenance() async throws {
        let env = try Env(photos: 2)
        let engine = FakeEngine([.success("# Страница 1"), .success("# Страница 2")])
        let center = env.center(engine)
        center.recognize(lectureID: env.lectureID, pageIDs: env.pages)
        #expect(center.isBusy(env.lectureID))
        try await waitIdle(center, env.lectureID)

        let requests = await engine.requests
        #expect(requests.count == 2)
        #expect(requests[0].prompt.contains("Правила для химии"))
        #expect(requests[0].prompt.hasSuffix("Изображение: ./\(env.pages[0]).jpg"))
        #expect(requests[0].images.map(\.lastPathComponent) == ["\(env.pages[0]).jpg"])
        #expect(requests[0].timeout == 30)

        for page in env.lecture.meta.notes {
            let text = try #require(page.text)
            #expect(text.origin == .model && text.engine == .claude && text.model == "fake")
            #expect(text.imageHash == page.imageHash && text.imageHash != nil)
            #expect(env.textStore.read(page.id, in: .notes)?.hasPrefix("# Страница") == true)
        }
        #expect(center.pendingPages(in: env.lecture).isEmpty)
    }

    @Test func rerecognizingManualEditKeepsBothVersions() async throws {
        let env = try Env(photos: 1)
        let engine = FakeEngine([.success("модель 1"), .success("модель 2")])
        let center = env.center(engine)
        let page = env.pages[0]
        center.recognize(lectureID: env.lectureID, pageIDs: [page])
        try await waitIdle(center, env.lectureID)

        env.library.saveEditedText("моя правка", pageID: page, lectureID: env.lectureID)
        env.library.saveEditedText("моя правка 2", pageID: page, lectureID: env.lectureID)
        #expect(env.lecture.meta.pageText(page)?.manuallyEdited == true)
        #expect(env.textStore.history(page, in: .notes).entries().count == 1)

        center.recognize(lectureID: env.lectureID, pageIDs: [page])
        try await waitIdle(center, env.lectureID)
        #expect(env.textStore.read(page, in: .notes) == "модель 2\n")
        let history = env.textStore.history(page, in: .notes).entries()
        #expect(history.count == 2)
        #expect(try String(contentsOf: history[0].file, encoding: .utf8) == "моя правка 2")
        #expect(history[0].info(PageText.self)?.manuallyEdited == true)
        #expect(env.lecture.meta.pageText(page)?.manuallyEdited == false)

        env.library.restoreVersion(history[0], pageID: page, lectureID: env.lectureID)
        #expect(env.textStore.read(page, in: .notes) == "моя правка 2")
        #expect(env.lecture.meta.pageText(page)?.manuallyEdited == true)
    }

    @Test func missingLoginStopsQueue() async throws {
        let env = try Env(photos: 3)
        let engine = FakeEngine([.failure(.notAuthenticated("Not logged in"))], delay: .milliseconds(50))
        let center = env.center(engine, parallel: 1)
        center.recognize(lectureID: env.lectureID, pageIDs: env.pages)
        try await waitIdle(center, env.lectureID)
        #expect(await engine.calls == 1)
        #expect(center.blockingError == .notAuthenticated("Not logged in"))
        for id in env.pages {
            #expect(center.state(of: id) == .failed(.notAuthenticated("Not logged in")))
        }
        #expect(env.lecture.meta.notes.allSatisfy { $0.text == nil })
    }

    @Test func cancelStopsEverything() async throws {
        let env = try Env(photos: 3)
        let engine = FakeEngine([], delay: .seconds(5))
        let center = env.center(engine, parallel: 1)
        center.recognize(lectureID: env.lectureID, pageIDs: env.pages)
        try await Task.sleep(for: .milliseconds(100))
        center.cancel(lectureID: env.lectureID)
        #expect(!center.isBusy(env.lectureID))
        try await Task.sleep(for: .milliseconds(200))
        #expect(env.pages.allSatisfy { center.state(of: $0) == nil })
        #expect(env.lecture.meta.notes.allSatisfy { $0.text == nil })
        #expect(await engine.calls == 1)
    }

    @Test func respectsParallelLimit() async throws {
        let env = try Env(photos: 3)
        let engine = FakeEngine([], delay: .milliseconds(80))
        let center = env.center(engine, parallel: 1)
        center.recognize(lectureID: env.lectureID, pageIDs: env.pages)
        try await waitIdle(center, env.lectureID)
        #expect(await engine.maxConcurrent == 1)
        #expect(await engine.calls == 3)
    }

    @Test func deletedPageIsSkipped() async throws {
        let env = try Env(photos: 2)
        let engine = FakeEngine([], delay: .milliseconds(50))
        let center = env.center(engine, parallel: 1)
        center.recognize(lectureID: env.lectureID, pageIDs: env.pages)
        env.library.deletePages([env.pages[1]], in: .notes, lectureID: env.lectureID)
        try await waitIdle(center, env.lectureID)
        #expect(await engine.calls == 1)
        #expect(env.lecture.meta.notes.count == 1)
    }

    @Test func duplicateRequestsAreIgnored() async throws {
        let env = try Env(photos: 1)
        let engine = FakeEngine([], delay: .milliseconds(50))
        let center = env.center(engine)
        center.recognize(lectureID: env.lectureID, pageIDs: env.pages)
        center.recognize(lectureID: env.lectureID, pageIDs: env.pages)
        try await waitIdle(center, env.lectureID)
        #expect(await engine.calls == 1)
    }

    @Test func firstManualTextOnUnrecognizedPage() throws {
        let env = try Env(photos: 1)
        env.library.saveEditedText("набрал сам", pageID: env.pages[0], lectureID: env.lectureID)
        let info = try #require(env.lecture.meta.pageText(env.pages[0]))
        #expect(info.origin == .manual && info.manuallyEdited)
        #expect(env.textStore.history(env.pages[0], in: .notes).entries().isEmpty)
    }
}

/// Сквозное распознавание с настоящим Claude Code (по флагу, как `ClaudeLiveTests`).
@Suite("Распознавание: живой вызов", .enabled(if: ProcessInfo.processInfo.environment["INKLING_LIVE_CLAUDE"] == "1"))
@MainActor
struct RecognitionLiveTests {
    @Test func recognizesSyntheticChemistryPage() async throws {
        let dir = try TempDir()
        let library = Library(root: dir.url.appendingPathComponent("Inkling"),
                              trasher: try FakeTrasher(bin: dir.url.appendingPathComponent("_bin")))
        library.open(root: library.root)
        #expect(library.createLecture(subject: "Общая и неорганическая химия", topic: "ОВР", date: .d("2026-10-14")))
        let lectureID = try #require(library.selection)
        let folder = try #require(library.lecture(id: lectureID)).folder
        let png = RawCLI.folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestData/synthetic/chem-page.png")
        let result = SourceImporter(paths: LecturePaths(folder: folder)).importFiles([png], into: .notes)
        library.mutate(lectureID) { $0.appendImported(result) }
        let pageID = try #require(result.notes.first?.id)

        let router = EngineRouter(primary: ClaudeCodeEngine(config: .init()), fallback: nil, settings: .init())
        let center = RecognitionCenter(library: library, router: { router }, timeout: { 180 }, maxParallel: { 1 })
        library.recognition = center
        center.recognize(lectureID: lectureID, pageIDs: [pageID])
        for _ in 0..<900 where center.isBusy(lectureID) { try await Task.sleep(for: .milliseconds(200)) }

        let lecture = try #require(library.lecture(id: lectureID))
        let text = try #require(PageTextStore(paths: LecturePaths(folder: lecture.folder)).read(pageID, in: .notes))
        print("Распознано:\n\(text)")
        #expect(text.contains(#"\ce{"#))
        #expect(text.contains("Окислитель") || text.contains("окислитель"))
        #expect(lecture.meta.pageText(pageID)?.model?.hasPrefix("claude-") == true)
    }
}

@Suite("История: форматы")
struct HistoryFormatTests {
    @Test func jsonContentAndLegacySidecars() throws {
        let dir = try TempDir()
        let history = HistoryStore(lectureFolder: dir.url, category: "c", key: "k")
        let study = dir.url.appendingPathComponent("study.json")
        try Data("{\"v\":1}".utf8).write(to: study)
        try history.save(study, info: PageText(origin: .manual, updatedAt: Date(timeIntervalSince1970: 0)),
                         now: Date(timeIntervalSince1970: 10))
        // Старая запись: описание в `<метка>.json` рядом с `.md`.
        let legacy = HistoryStore.stamp(Date(timeIntervalSince1970: 5))
        try Data("старый текст".utf8).write(to: history.folder.appendingPathComponent("\(legacy).md"))
        try AtomicFile.writeJSON(PageText(origin: .model, updatedAt: Date(timeIntervalSince1970: 0)),
                                 to: history.folder.appendingPathComponent("\(legacy).json"))

        let entries = history.entries()
        #expect(entries.count == 2)
        #expect(entries[0].file.lastPathComponent.hasSuffix(".json"))
        #expect(entries[0].info(PageText.self)?.origin == .manual)
        #expect(entries[1].file.pathExtension == "md")
        #expect(entries[1].info(PageText.self)?.origin == .model)
    }
}

/// Сравнение обычного и подробного распознавания одной настоящей страницы (по флагу, тратит лимит).
/// `INKLING_LIVE_PAGE` — путь к фото; результаты пишутся в `INKLING_LIVE_OUT_DIR` (`normal.md`, `detailed.md`).
@Suite("Распознавание: обычное и подробное", .enabled(if: ProcessInfo.processInfo.environment["INKLING_LIVE_CLAUDE"] == "1"))
@MainActor
struct DetailedRecognitionLiveTests {
    @Test func comparesNormalAndDetailed() async throws {
        let environment = ProcessInfo.processInfo.environment
        let page = URL(fileURLWithPath: try #require(environment["INKLING_LIVE_PAGE"], "задайте INKLING_LIVE_PAGE"))
        let dir = try TempDir()
        let library = Library(root: dir.url.appendingPathComponent("Inkling"),
                              trasher: try FakeTrasher(bin: dir.url.appendingPathComponent("_bin")))
        library.open(root: library.root)
        #expect(library.createLecture(subject: "Высшая алгебра", topic: "Сравнение", date: .d("2026-10-16")))
        let lectureID = try #require(library.selection)
        let folder = try #require(library.lecture(id: lectureID)).folder
        let result = SourceImporter(paths: LecturePaths(folder: folder)).importFiles([page], into: .notes)
        library.mutate(lectureID) { $0.appendImported(result) }
        let pageID = try #require(result.notes.first?.id)

        let router = EngineRouter(primary: ClaudeCodeEngine(config: .init()), fallback: nil, settings: .init())
        let center = RecognitionCenter(library: library, router: { router }, timeout: { 240 }, maxParallel: { 1 })
        library.recognition = center
        var outputs: [(String, String)] = []
        let layouts: [String: ImageProcessor.DetailedLayout] = [
            "rows3": .init(rows: 3, columns: 1), "rows5": .init(rows: 5, columns: 1),
            "grid2x3": .init(rows: 3, columns: 2), "grid2x4": .init(rows: 4, columns: 2),
        ]
        let variants = (environment["INKLING_LIVE_VARIANTS"] ?? "normal,rows3").split(separator: ",").map(String.init)
        for name in variants {
            let detailed = name != "normal"
            if let layout = layouts[name] { ImageProcessor.detailedLayout = layout }
            let started = Date()
            center.recognize(lectureID: lectureID, pageIDs: [pageID], detailed: detailed)
            for _ in 0..<1500 where center.isBusy(lectureID) { try await Task.sleep(for: .milliseconds(200)) }
            let lecture = try #require(library.lecture(id: lectureID))
            let text = try #require(PageTextStore(paths: LecturePaths(folder: lecture.folder)).read(pageID, in: .notes),
                                    "\(name): \(String(describing: center.state(of: pageID)))")
            let illegible = text.components(separatedBy: "[неразборчиво]").count - 1
            let guesses = text.components(separatedBy: "[?").count - 1
            print("\(name): \(Int(Date().timeIntervalSince(started))) с, символов \(text.count), неразборчиво \(illegible), догадок \(guesses)")
            outputs.append((name, text))
        }
        if let out = environment["INKLING_LIVE_OUT_DIR"] {
            for (name, text) in outputs { try text.write(toFile: "\(out)/\(name).md", atomically: true, encoding: .utf8) }
        }
    }
}
