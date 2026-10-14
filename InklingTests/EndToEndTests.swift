import Foundation
import PDFKit
import Testing
@testable import Inkling

/// Каким движком идёт живой сквозной прогон: по флагам окружения.
enum LiveEngine {
    static var selected: EngineID? {
        let env = ProcessInfo.processInfo.environment
        if env["INKLING_LIVE_CLAUDE"] == "1" { return .claude }
        if env["INKLING_LIVE_OLLAMA"] == "1" { return .ollama }
        return nil
    }
}

/// Сквозной прогон всего конвейера с настоящим движком (SPEC, раздел 10). По флагу, как другие живые тесты:
/// `INKLING_LIVE_CLAUDE=1` — Claude Code, `INKLING_LIVE_OLLAMA=1` — локальная Ollama (этап 8).
/// Берёт синтетические данные из `TestData/synthetic` и, если есть, реальные фото из `TestData/real`.
/// Результаты кладёт в `INKLING_E2E_OUT` (если задано) для `docs/e2e-report.md`.
@Suite("Сквозной прогон", .enabled(if: LiveEngine.selected != nil))
@MainActor
struct EndToEndTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    @Test func fullPipeline() async throws {
        let dir = try TempDir()
        let out = ProcessInfo.processInfo.environment["INKLING_E2E_OUT"].map { URL(fileURLWithPath: $0) } ?? dir.url
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var log: [String] = []
        func note(_ s: String) { log.append(s); print("E2E: \(s)") }

        let library = Library(root: dir.url.appendingPathComponent("Inkling"),
                              trasher: try FakeTrasher(bin: dir.url.appendingPathComponent("_bin")))
        library.open(root: library.root)
        let local = LiveEngine.selected == .ollama
        let engine: any AIEngine = local ? OllamaEngine(config: .init()) : ClaudeCodeEngine(config: .init())
        note("Движок: \(engine.id.title)")
        let router = EngineRouter(primary: engine, fallback: nil, settings: .init(maxParallel: 2))
        let recognition = RecognitionCenter(library: library, router: { router }, timeout: { 180 }, maxParallel: { 2 })
        let assembly = AssemblyCenter(library: library, router: { router },
                                      threshold: { local ? EngineCenter.localChunkThreshold : 40_000 })
        let study = StudyCenter(library: library, router: { router })
        library.recognition = recognition

        #expect(library.createLecture(subject: "Общая и неорганическая химия", topic: "ОВР", date: .d("2026-10-14")))
        let id = try #require(library.selection)

        // Импорт: синтетика + реальные фото, если они есть.
        let synthetic = Self.repo.appendingPathComponent("TestData/synthetic")
        var photos = [synthetic.appendingPathComponent("chem-page.png")]
        let real = Self.repo.appendingPathComponent("TestData/real")
        let realPhotos = ((try? FileManager.default.contentsOfDirectory(at: real, includingPropertiesForKeys: nil)) ?? [])
            .filter { ImageProcessor.isSupportedImage($0) }.sorted { $0.path < $1.path }
        photos += realPhotos
        note("Фото: синтетика 1, реальные \(realPhotos.count)")

        var started = Date()
        library.importFiles(photos, into: .notes, lectureID: id)
        library.importFiles([synthetic.appendingPathComponent("slides.pdf")], into: .slides, lectureID: id)
        for _ in 0..<600 where library.importProgress != nil || (library.lecture(id: id)?.meta.notes.count ?? 0) < photos.count {
            try await Task.sleep(for: .milliseconds(100))
        }
        var lecture = try #require(library.lecture(id: id))
        note("Импорт: страниц \(lecture.meta.notes.count), слайдов \(lecture.meta.slides.count), "
             + "слайдов-картинок \(lecture.meta.slides.filter(\.usesImage).count), "
             + String(format: "%.1f с", Date().timeIntervalSince(started)))
        for page in lecture.meta.notes {
            note("  страница: обрезка \(page.crop.quad == nil ? "нет" : "да"), дата съёмки \(page.captureDate.map { "\($0)" } ?? "нет")")
        }

        // Распознавание стартует само после импорта.
        started = Date()
        // Локальная модель в 5–10 раз медленнее: ждём дольше.
        let patience = local ? 5 : 1
        for _ in 0..<(1800 * patience) where recognition.isBusy(id) || recognition.pendingPages(in: library.lecture(id: id)!).count > 0 {
            if recognition.blockingError != nil { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        lecture = try #require(library.lecture(id: id))
        #expect(recognition.blockingError == nil)
        let texts = PageTextStore(paths: LecturePaths(folder: lecture.folder))
        note("Распознавание: " + String(format: "%.1f с", Date().timeIntervalSince(started))
             + ", без текста: \(recognition.pendingPages(in: lecture).count)")
        for page in lecture.meta.notes {
            let text = texts.read(page.id, in: .notes) ?? ""
            note("  страница (\(page.text?.model ?? "?")): \(text.count) симв., [неразборчиво]: "
                 + "\(text.components(separatedBy: "[неразборчиво]").count - 1)")
            try? text.write(to: out.appendingPathComponent("page-\(page.id.prefix(6)).md"), atomically: true, encoding: .utf8)
        }

        // Сборка.
        let readiness = assembly.readiness(lecture)
        note("Сборка: режим \(readiness.plan?.mode.rawValue ?? "-"), вызовов \(readiness.plan?.calls ?? 0)")
        started = Date()
        assembly.assemble(id)
        for _ in 0..<(3000 * patience) where assembly.isRunning(id) { try await Task.sleep(for: .milliseconds(200)) }
        #expect(assembly.errors[id] == nil, "\(String(describing: assembly.errors[id]))")
        lecture = try #require(library.lecture(id: id))
        let konspekt = try #require(KonspektStore(folder: lecture.folder).read())
        try konspekt.write(to: out.appendingPathComponent("konspekt.md"), atomically: true, encoding: .utf8)
        note("Конспект: " + String(format: "%.1f с", Date().timeIntervalSince(started)) + ", \(konspekt.count) симв., "
             + "⚠️: \(konspekt.components(separatedBy: "⚠️").count - 1), 📎: \(konspekt.components(separatedBy: "📎").count - 1)")

        // Учебные материалы.
        started = Date()
        study.generate(id)
        for _ in 0..<(3000 * patience) where study.isRunning(id) { try await Task.sleep(for: .milliseconds(200)) }
        #expect(study.errors[id] == nil, "\(String(describing: study.errors[id]))")
        let materials = try #require(StudyStore(folder: lecture.folder).readStudy())
        try? FileManager.default.copyItem(at: StudyStore(folder: lecture.folder).studyURL,
                                          to: out.appendingPathComponent("study.json"))
        note("Материалы: " + String(format: "%.1f с", Date().timeIntervalSince(started))
             + ", резюме \(materials.summary.count), термины \(materials.terms.count), вопросы \(materials.questions.count), "
             + "тест \(materials.quiz.count), карточки \(materials.flashcards.count)")

        // Экспорт.
        let pdf = out.appendingPathComponent("konspekt.pdf")
        try await PDFExporter().export(markdown: konspekt, title: "ОВР", to: pdf)
        let pages = PDFDocument(url: pdf)?.pageCount ?? 0
        let anki = AnkiExporter.export(materials, progress: StudyProgress(), subject: lecture.meta.subject,
                                       topic: lecture.meta.topic, includeQuestions: true)
        try anki.write(to: out.appendingPathComponent("anki.csv"), atomically: true, encoding: .utf8)
        note("Экспорт: PDF \(pages) стр., Anki \(anki.split(separator: "\n").count - 3) строк")
        #expect(pages >= 1)

        try log.joined(separator: "\n").write(to: out.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
    }
}
