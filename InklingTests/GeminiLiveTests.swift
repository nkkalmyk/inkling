import Foundation
import Testing
@testable import Inkling

/// Живые вызовы Gemini (по флагу, тратят квоту ключа и отправляют синтетические страницы в Google):
/// `TEST_RUNNER_INKLING_LIVE_GEMINI=1 TEST_RUNNER_INKLING_LIVE_GEMINI_KEY=<ключ>`; модель — `INKLING_LIVE_GEMINI_MODEL`.
/// Ключ берётся только из окружения запуска, в файлы и вывод не попадает.
@Suite("Gemini: живой вызов", .enabled(if: ProcessInfo.processInfo.environment["INKLING_LIVE_GEMINI"] == "1"), .serialized)
@MainActor
struct GeminiLiveTests {
    private static let environment = ProcessInfo.processInfo.environment

    private var engine: GeminiEngine {
        var config = GeminiEngine.Config()
        if let model = Self.environment["INKLING_LIVE_GEMINI_MODEL"], !model.isEmpty { config.model = model }
        let key = Self.environment["INKLING_LIVE_GEMINI_KEY"]
        return GeminiEngine(config: config, apiKey: { key })
    }

    private var router: EngineRouter { EngineRouter(primary: engine, fallback: nil, settings: .init(maxParallel: 1)) }

    private static var testData: URL {
        RawCLI.folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestData/synthetic")
    }

    @Test func connectionWorks() async {
        let report = await engine.checkConnection()
        #expect(report.isOK, "\(String(describing: report.error?.details))")
        print("Подключение: модель \(report.model ?? "?"), \(report.duration ?? 0) с")
    }

    // MARK: Распознавание

    private func recognize(_ file: String, into section: SourceSection = .notes, subject: String, detailed: Bool = false) async throws
        -> (text: String, model: String?) {
        let dir = try TempDir()
        let library = Library(root: dir.url.appendingPathComponent("Inkling"),
                              trasher: try FakeTrasher(bin: dir.url.appendingPathComponent("_bin")))
        library.open(root: library.root)
        #expect(library.createLecture(subject: subject, topic: "Проверка Gemini", date: .d("2026-11-04")))
        let lectureID = try #require(library.selection)
        let folder = try #require(library.lecture(id: lectureID)).folder
        let result = SourceImporter(paths: LecturePaths(folder: folder)).importFiles([Self.testData.appendingPathComponent(file)],
                                                                                    into: section)
        library.mutate(lectureID) { $0.appendImported(result) }
        let pageID = try #require((section == .notes ? result.notes.first?.id : result.slides.first?.id))

        let router = self.router
        let center = RecognitionCenter(library: library, router: { router }, timeout: { 180 }, maxParallel: { 1 })
        library.recognition = center
        center.recognize(lectureID: lectureID, pageIDs: [pageID], detailed: detailed)
        for _ in 0..<900 where center.isBusy(lectureID) { try await Task.sleep(for: .milliseconds(200)) }
        let lecture = try #require(library.lecture(id: lectureID))
        let text = try #require(PageTextStore(paths: LecturePaths(folder: lecture.folder)).read(pageID, in: section),
                                "\(String(describing: center.state(of: pageID)))")
        print("Распознано (\(file), подробно: \(detailed)):\n\(text)")
        return (text, lecture.meta.pageText(pageID)?.model)
    }

    @Test func recognizesChemistryPage() async throws {
        let result = try await recognize("chem-page.png", subject: "Общая и неорганическая химия")
        #expect(result.text.contains(#"\ce{"#))
        #expect(result.text.lowercased().contains("окислитель"))
        #expect(result.model?.hasPrefix("gemini") == true, "\(String(describing: result.model))")
    }

    @Test func recognizesMathPage() async throws {
        let result = try await recognize("math-page.png", subject: "Математический анализ")
        #expect(result.text.contains(#"\lim"#))
        #expect(result.text.contains(#"\int"#))
    }

    @Test func recognizesDetailed() async throws {
        let result = try await recognize("math-page.png", subject: "Математический анализ", detailed: true)
        #expect(result.text.contains(#"\lim"#))
        #expect(result.text.contains(#"\int"#))
    }

    @Test func recognizesSlides() async throws {
        let result = try await recognize("slides.pdf", into: .slides, subject: "Общая и неорганическая химия")
        #expect(!result.text.isEmpty)
    }

    // MARK: Сборка и учебные материалы

    @Test func assemblesExactKonspekt() async throws {
        let env = try AssemblyCenterTests.Env(pages: [
            "Тема: ОВР\n1. Окислитель принимает электроны,",
            "восстановитель отдаёт.\nПример: $\\ce{2H2 + O2 -> 2H2O}$\nСтепень окисления O в H2O равна +2.",
        ])
        let router = self.router
        let center = AssemblyCenter(library: env.library, router: { router }, threshold: { 40_000 }, style: { .faithful })
        center.assemble(env.lectureID)
        for _ in 0..<900 where center.isRunning(env.lectureID) { try await Task.sleep(for: .milliseconds(200)) }
        #expect(center.errors[env.lectureID] == nil, "\(String(describing: center.errors[env.lectureID]))")
        let text = try #require(env.konspekt.read())
        print("Точный конспект:\n\(text)")
        #expect(text.contains(#"\ce{"#))
        #expect(text.contains("⚠️"), "Ошибку «+2» модель должна пометить")
        #expect(!text.contains("--- Страница"))
    }

    @Test func assemblesStudyKonspektFromPhotoThenStudyMaterials() async throws {
        let env = try AssemblyCenterTests.Env(pages: ["Тема: ОВР, окислитель принимает электроны"])
        let paths = LecturePaths(folder: env.lecture.folder)
        let photo = paths.notePhoto("p0")
        try FileManager.default.createDirectory(at: photo.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: Self.testData.appendingPathComponent("chem-page.png")).write(to: photo)

        let router = self.router
        let center = AssemblyCenter(library: env.library, router: { router }, threshold: { 40_000 }, style: { .study }, model: { "" })
        center.assemble(env.lectureID)
        for _ in 0..<1500 where center.isRunning(env.lectureID) { try await Task.sleep(for: .milliseconds(200)) }
        #expect(center.errors[env.lectureID] == nil, "\(String(describing: center.errors[env.lectureID]))")
        let text = try #require(env.konspekt.read())
        print("Учебный конспект:\n\(text)")
        #expect(text.hasPrefix("#"))
        #expect(text.lowercased().contains("окислитель"))
        #expect(env.library.lecture(id: env.lectureID)?.meta.konspekt?.model?.hasPrefix("gemini") == true)

        let study = StudyCenter(library: env.library, router: { router })
        study.generate(env.lectureID)
        for _ in 0..<1500 where study.isRunning(env.lectureID) { try await Task.sleep(for: .milliseconds(200)) }
        #expect(study.errors[env.lectureID] == nil, "\(String(describing: study.errors[env.lectureID]))")
        let materials = try #require(StudyStore(folder: env.lecture.folder).readStudy())
        print("Вопросов \(materials.quiz.count), карточек \(materials.flashcards.count)")
        #expect(materials.quiz.count >= 4)
        #expect(!materials.flashcards.isEmpty)
    }
}
