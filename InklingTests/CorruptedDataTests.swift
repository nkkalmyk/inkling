import Foundation
import Testing
@testable import Inkling

/// Файлы данных могут прийти из iCloud-конфликта, чужой папки или ручной правки: приложение не должно падать.
@Suite("Повреждённые файлы данных")
struct CorruptedDataTests {
    let dir: TempDir

    init() throws { dir = try TempDir() }

    private func write(_ text: String, as name: String) throws {
        try Data(text.utf8).write(to: dir.url.appendingPathComponent(name))
    }

    private static let garbage = [
        "", "   ", "null", "[]", "42", "\"строка\"", "{", "{\"items\": 5}", "{\"schemaVersion\": \"x\"}",
        "\u{0}\u{1}\u{2}", "{\"items\": {\"a\": {\"result\": \"maybe\", \"date\": \"вчера\"}}}",
    ]

    @Test func garbageProgressFallsBackToEmpty() throws {
        for text in Self.garbage {
            try write(text, as: "progress.json")
            let progress = StudyStore(folder: dir.url).readProgress()
            #expect(progress.isEmpty, "«\(text)»")
        }
    }

    @Test func garbageStudyReadsAsNil() throws {
        for text in Self.garbage + ["{\"summary\": [], \"terms\": [], \"questions\": [], \"quiz\": 1, \"flashcards\": []}"] {
            try write(text, as: "study.json")
            #expect(StudyStore(folder: dir.url).readStudy() == nil, "«\(text)»")
        }
    }

    @Test func garbageMetaIsReportedAsUnavailableLecture() throws {
        let root = dir.url.appendingPathComponent("Inkling")
        let store = LibraryStore(root: root, trasher: try FakeTrasher(bin: dir.url.appendingPathComponent("_bin")))
        try store.bootstrap()
        let subject = root.appendingPathComponent("Высшая алгебра")
        for (i, text) in Self.garbage.enumerated() {
            let lecture = subject.appendingPathComponent("лекция \(i)")
            try FileManager.default.createDirectory(at: lecture, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: lecture.appendingPathComponent(LibraryStore.metaFileName))
        }
        let loaded = try #require(try store.loadSubjects().first { $0.name == "Высшая алгебра" })
        #expect(loaded.lectures.isEmpty)
        #expect(loaded.unavailable.count == Self.garbage.count)
    }

    @Test func quizWithMismatchedOptionsAndDuplicateIDsDoesNotCrash() throws {
        let json = """
        {"schemaVersion": 1, "summary": ["s"], "terms": [], "questions": [], "flashcards": [],
         "quiz": [
           {"id": "z1", "question": "a", "options": ["1","2","3","4"], "correctIndex": 9, "explanation": "e"},
           {"id": "z1", "question": "b", "options": ["1"], "correctIndex": 0, "explanation": "e"},
           {"id": "z2", "question": "c", "options": [], "correctIndex": -1, "explanation": "e"}
         ]}
        """
        try write(json, as: "study.json")
        let study = try #require(StudyStore(folder: dir.url).readStudy())
        var session = QuizSession(items: study.quiz, seed: 7)
        while !session.isFinished {
            _ = session.currentOptions
            session.answer(0)
            session.next()
        }
        #expect(session.answers.count <= study.quiz.count)
    }
}
