import Foundation
import Testing
@testable import Inkling

@Suite("Очистка остатков прошлого запуска")
struct LeftoversCleanupTests {
    let dir: TempDir

    init() throws { dir = try TempDir() }

    @MainActor
    @Test func staleImportFoldersAreRemovedFreshAndForeignAreKept() throws {
        let fm = FileManager.default
        let old = dir.url.appendingPathComponent("Inkling-import-OLD")
        let fresh = dir.url.appendingPathComponent("Inkling-import-FRESH")
        let foreign = dir.url.appendingPathComponent("other-folder")
        for url in [old, fresh, foreign] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        try Data("x".utf8).write(to: old.appendingPathComponent("photo.jpg"))
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 24 * 3600)], ofItemAtPath: old.path)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 24 * 3600)], ofItemAtPath: foreign.path)

        #expect(ImportStaging.removeStale(in: dir.url) == 1)
        #expect(!fm.fileExists(atPath: old.path))
        #expect(fm.fileExists(atPath: fresh.path))
        #expect(fm.fileExists(atPath: foreign.path))
    }

    /// Регресс A16 (аудит 2026-11): папки вызовов CLI и экспорта предмета не убирались после аварийного выхода.
    @MainActor
    @Test func runAndExportFoldersAreCleanedOllamaFilesAreKept() throws {
        let fm = FileManager.default
        let old = Date().addingTimeInterval(-3 * 24 * 3600)
        let names = ["Inkling-run-\(UUID().uuidString)", "Inkling-\(UUID().uuidString)", "Inkling-ollama.log", "Inkling-ollama.pid",
                     "Inkling-notes"]
        for name in names {
            let url = dir.url.appendingPathComponent(name)
            if name.contains(".") { try Data("x".utf8).write(to: url) } else { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        #expect(ImportStaging.removeStale(in: dir.url) == 2)
        #expect(!fm.fileExists(atPath: dir.url.appendingPathComponent(names[0]).path))
        #expect(!fm.fileExists(atPath: dir.url.appendingPathComponent(names[1]).path))
        for kept in names.dropFirst(2) { #expect(fm.fileExists(atPath: dir.url.appendingPathComponent(kept).path)) }
    }

    @Test func orphanServerIsStoppedOnlyWhenNameMatches() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["60"]
        try sleeper.run()
        defer { if sleeper.isRunning { sleeper.terminate() } }

        let pidFile = dir.url.appendingPathComponent("ollama.pid")
        try "\(sleeper.processIdentifier)".write(to: pidFile, atomically: true, encoding: .utf8)

        // Чужое имя процесса: PID мог быть переиспользован, процесс не трогаем.
        #expect(OllamaServer.reapOrphan(pidFile: pidFile, executableName: "ollama") == false)
        #expect(sleeper.isRunning)
        #expect(!FileManager.default.fileExists(atPath: pidFile.path))

        try "\(sleeper.processIdentifier)".write(to: pidFile, atomically: true, encoding: .utf8)
        #expect(OllamaServer.reapOrphan(pidFile: pidFile, executableName: "sleep"))
        sleeper.waitUntilExit()
        #expect(!sleeper.isRunning)
    }

    @Test func reapIgnoresMissingAndGarbagePIDFile() throws {
        let pidFile = dir.url.appendingPathComponent("ollama.pid")
        #expect(OllamaServer.reapOrphan(pidFile: pidFile) == false)
        for text in ["", "abc", "-5", "0", "1"] {
            try text.write(to: pidFile, atomically: true, encoding: .utf8)
            #expect(OllamaServer.reapOrphan(pidFile: pidFile) == false, "«\(text)»")
        }
    }
}
