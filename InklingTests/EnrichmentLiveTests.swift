import Foundation
import Testing
@testable import Inkling

/// Живое «Дополнить» с настоящим Claude Code (по флагу, тратит лимит). Конспект берётся из файла
/// `INKLING_LIVE_KONSPEKT`, копия работает во временной лекции; результат пишется в `INKLING_LIVE_OUT`.
@Suite("Дополнение: живой вызов", .enabled(if: ProcessInfo.processInfo.environment["INKLING_LIVE_CLAUDE"] == "1"))
@MainActor
struct EnrichmentLiveTests {
    @Test func enrichesRealKonspekt() async throws {
        let environment = ProcessInfo.processInfo.environment
        let source = try #require(environment["INKLING_LIVE_KONSPEKT"], "задайте INKLING_LIVE_KONSPEKT")
        let original = try String(contentsOfFile: source, encoding: .utf8)
        let env = try AssemblyCenterTests.Env(pages: ["x"])
        let store = KonspektStore(folder: env.lecture.folder)
        try store.write(original, previous: nil)
        env.library.mutate(env.lectureID) {
            let now = JSONCoding.rounded(Date())
            $0.konspekt = ArtifactInfo(createdAt: now, updatedAt: now, inputHash: "x")
        }

        let router = EngineRouter(primary: ClaudeCodeEngine(config: .init()), fallback: nil, settings: .init())
        let center = EnrichmentCenter(library: env.library, router: { router })
        let started = Date()
        center.enrich(env.lectureID)
        for _ in 0..<3000 where center.isRunning(env.lectureID) { try await Task.sleep(for: .milliseconds(200)) }
        let error = center.errors[env.lectureID]
        #expect(error == nil, "\(String(describing: error))")

        let result = try #require(store.read())
        let additions = Enrichment.additions(in: result)
        var counts: [String: Int] = [:]
        for addition in additions { counts[addition.kind.title, default: 0] += 1 }
        let info = env.library.lecture(id: env.lectureID)?.meta.konspekt?.enrichment
        print("Время: \(Int(Date().timeIntervalSince(started))) с")
        print("Блоков: \(additions.count) \(counts), убрано проверкой: \(info?.removedByCheck ?? -1)")
        print("Текст автора сохранён: \(Enrichment.preservesAuthorText(original: original, enriched: result))")
        if let out = environment["INKLING_LIVE_OUT"] {
            try result.write(toFile: out, atomically: true, encoding: .utf8)
        }
        #expect(Enrichment.preservesAuthorText(original: original, enriched: result))
    }
}
