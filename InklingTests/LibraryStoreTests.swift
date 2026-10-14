import Foundation
import Testing
@testable import Inkling

@Suite("LibraryStore")
struct LibraryStoreTests {
    let dir: TempDir
    let trasher: FakeTrasher
    let store: LibraryStore

    init() throws {
        dir = try TempDir()
        trasher = try FakeTrasher(bin: dir.url.appendingPathComponent("_bin"))
        store = LibraryStore(root: dir.url.appendingPathComponent("Inkling"), trasher: trasher)
    }

    // MARK: Корень и предметы

    @Test func bootstrapCreatesDefaultSubjectsOnlyOnce() throws {
        #expect(try store.bootstrap())
        #expect(try store.loadSubjects().map(\.name).sorted() == LibraryStore.defaultSubjects.sorted())

        try store.deleteSubject("Высшая алгебра")
        #expect(try store.bootstrap() == false)
        #expect(try !store.loadSubjects().map(\.name).contains("Высшая алгебра"))
    }

    @Test func bootstrapDoesNotSeedExistingRoot() throws {
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        #expect(try store.bootstrap() == false)
        #expect(try store.loadSubjects().isEmpty)
    }

    @Test func listingSkipsServiceAndHiddenFolders() throws {
        try store.bootstrap()
        for name in ["_prompts", ".git"] {
            try FileManager.default.createDirectory(at: store.root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data().write(to: store.root.appendingPathComponent("заметка.txt"))
        #expect(try store.loadSubjects().count == 3)
    }

    @Test func createSubjectRejectsDuplicatesIgnoringCase() throws {
        try store.bootstrap()
        try store.createSubject(named: "Физика")
        #expect(throws: LibraryError.subjectExists("Физика")) { try store.createSubject(named: "физика") }
        #expect(throws: LibraryError.emptyName) { try store.createSubject(named: "   ") }
    }

    @Test func renameSubjectRenamesFolderAndUpdatesMeta() throws {
        try store.bootstrap()
        let lecture = try store.createLecture(subject: "Высшая алгебра", topic: "Матрицы", date: .d("2026-10-01"))
        try store.renameSubject("Высшая алгебра", to: "Алгебра и геометрия")

        let subjects = try store.loadSubjects()
        #expect(!subjects.map(\.name).contains("Высшая алгебра"))
        let renamed = try #require(subjects.first { $0.name == "Алгебра и геометрия" })
        #expect(renamed.lectures.map(\.id) == [lecture.id])
        #expect(renamed.lectures[0].meta.subject == "Алгебра и геометрия")
    }

    @Test func renameSubjectCaseOnly() throws {
        try store.bootstrap()
        try store.renameSubject("Высшая алгебра", to: "высшая алгебра")
        #expect(try store.loadSubjects().map(\.name).contains("высшая алгебра"))
    }

    @Test func renameSubjectIntoExistingFails() throws {
        try store.bootstrap()
        #expect(throws: LibraryError.subjectExists("Математический анализ")) {
            try store.renameSubject("Высшая алгебра", to: "Математический анализ")
        }
    }

    @Test func deleteSubjectGoesToTrash() throws {
        try store.bootstrap()
        _ = try store.createLecture(subject: "Математический анализ", topic: "Пределы", date: .d("2026-10-01"))
        try store.deleteSubject("Математический анализ")
        #expect(trasher.trashed == ["Математический анализ"])
        #expect(try store.loadSubjects().count == 2)
    }

    // MARK: Лекции

    @Test func createLectureWritesMetaInNamedFolder() throws {
        try store.bootstrap()
        let lecture = try store.createLecture(subject: "Общая и неорганическая химия", topic: "  ОВР: основы ",
                                              date: .d("2026-10-14"))
        #expect(lecture.folder.lastPathComponent == "2026-10-14 — ОВР- основы")
        #expect(lecture.meta.topic == "ОВР: основы")
        #expect(lecture.meta.subject == "Общая и неорганическая химия")
        #expect(try store.readMeta(in: lecture.folder) == lecture.meta)
    }

    @Test func createLectureCreatesMissingSubjectAndMatchesExistingIgnoringCase() throws {
        try store.bootstrap()
        let physics = try store.createLecture(subject: "Физика", topic: "Кинематика", date: .d("2026-09-01"))
        #expect(physics.meta.subject == "Физика")
        let algebra = try store.createLecture(subject: "высшая АЛГЕБРА", topic: "Векторы", date: .d("2026-09-02"))
        #expect(algebra.meta.subject == "Высшая алгебра")
        #expect(try store.loadSubjects().count == 4)
    }

    @Test func sameDateAndTopicGetSuffix() throws {
        try store.bootstrap()
        let first = try store.createLecture(subject: "Высшая алгебра", topic: "Матрицы", date: .d("2026-10-14"))
        let second = try store.createLecture(subject: "Высшая алгебра", topic: "Матрицы", date: .d("2026-10-14"))
        let third = try store.createLecture(subject: "Высшая алгебра", topic: "матрицы", date: .d("2026-10-14"))
        #expect(first.folder.lastPathComponent == "2026-10-14 — Матрицы")
        #expect(second.folder.lastPathComponent == "2026-10-14 — Матрицы (2)")
        #expect(third.folder.lastPathComponent == "2026-10-14 — матрицы (3)")
        #expect(Set([first.id, second.id, third.id]).count == 3)
    }

    @Test func createLectureRejectsEmptyTopic() throws {
        try store.bootstrap()
        #expect(throws: LibraryError.emptyName) {
            try store.createLecture(subject: "Высшая алгебра", topic: " \n ", date: .d("2026-10-14"))
        }
    }

    @Test func lecturesSortedNewestFirst() throws {
        try store.bootstrap()
        for (topic, date) in [("Б", "2026-09-01"), ("В", "2026-10-01"), ("А", "2026-09-01")] {
            _ = try store.createLecture(subject: "Высшая алгебра", topic: topic, date: .d(date))
        }
        let subject = try #require(try store.loadSubjects().first { $0.name == "Высшая алгебра" })
        #expect(subject.lectures.map(\.meta.topic) == ["В", "А", "Б"])
    }

    @Test func updateTopicAndDateRenamesFolderKeepingId() throws {
        try store.bootstrap()
        let original = try store.createLecture(subject: "Высшая алгебра", topic: "Матрицы", date: .d("2026-10-14"))
        try Data("страница".utf8).write(to: original.folder.appendingPathComponent("page.md"))

        let updated = try store.updateLecture(id: original.id, subject: "Высшая алгебра", topic: "Определители",
                                              date: .d("2026-10-15"))
        #expect(updated.id == original.id)
        #expect(updated.folder.lastPathComponent == "2026-10-15 — Определители")
        #expect(!FileManager.default.fileExists(atPath: original.folder.path))
        #expect(FileManager.default.fileExists(atPath: updated.folder.appendingPathComponent("page.md").path))
        #expect(try store.readMeta(in: updated.folder).topic == "Определители")
    }

    @Test func updateWithoutNameChangeKeepsSuffixedFolder() throws {
        try store.bootstrap()
        _ = try store.createLecture(subject: "Высшая алгебра", topic: "Матрицы", date: .d("2026-10-14"))
        let second = try store.createLecture(subject: "Высшая алгебра", topic: "Матрицы", date: .d("2026-10-14"))
        let updated = try store.updateLecture(id: second.id, subject: "Высшая алгебра", topic: "Матрицы",
                                              date: .d("2026-10-14"))
        #expect(updated.folder.lastPathComponent == "2026-10-14 — Матрицы (2)")
    }

    @Test func updateIntoTakenNameGetsSuffix() throws {
        try store.bootstrap()
        _ = try store.createLecture(subject: "Высшая алгебра", topic: "Матрицы", date: .d("2026-10-14"))
        let other = try store.createLecture(subject: "Высшая алгебра", topic: "Векторы", date: .d("2026-10-14"))
        let updated = try store.updateLecture(id: other.id, subject: "Высшая алгебра", topic: "Матрицы",
                                              date: .d("2026-10-14"))
        #expect(updated.folder.lastPathComponent == "2026-10-14 — Матрицы (2)")
    }

    @Test func updateCaseOnlyRenamesFolder() throws {
        try store.bootstrap()
        let lecture = try store.createLecture(subject: "Высшая алгебра", topic: "матрицы", date: .d("2026-10-14"))
        let updated = try store.updateLecture(id: lecture.id, subject: "Высшая алгебра", topic: "Матрицы",
                                              date: .d("2026-10-14"))
        #expect(updated.folder.lastPathComponent == "2026-10-14 — Матрицы")
        let names = dir.contents(of: "Inkling/Высшая алгебра")
        #expect(names == ["2026-10-14 — Матрицы"])
    }

    @Test func updateMovesLectureToAnotherSubject() throws {
        try store.bootstrap()
        let lecture = try store.createLecture(subject: "Высшая алгебра", topic: "Пределы", date: .d("2026-10-14"))
        let moved = try store.updateLecture(id: lecture.id, subject: "Математический анализ", topic: "Пределы",
                                            date: .d("2026-10-14"))
        #expect(moved.folder.deletingLastPathComponent().lastPathComponent == "Математический анализ")
        #expect(moved.meta.subject == "Математический анализ")
        let subjects = try store.loadSubjects()
        #expect(subjects.first { $0.name == "Высшая алгебра" }?.lectures.isEmpty == true)
        #expect(subjects.first { $0.name == "Математический анализ" }?.lectures.map(\.id) == [lecture.id])
    }

    @Test func findLectureSurvivesExternalRename() throws {
        try store.bootstrap()
        let lecture = try store.createLecture(subject: "Высшая алгебра", topic: "Матрицы", date: .d("2026-10-14"))
        let renamed = lecture.folder.deletingLastPathComponent().appendingPathComponent("переименовано в Finder")
        try FileManager.default.moveItem(at: lecture.folder, to: renamed)

        let found = try #require(try store.findLecture(id: lecture.id))
        #expect(found.folder.lastPathComponent == "переименовано в Finder")
        let updated = try store.updateLecture(id: lecture.id, subject: "Высшая алгебра", topic: "Матрицы",
                                              date: .d("2026-10-14"))
        #expect(updated.folder.lastPathComponent == "2026-10-14 — Матрицы")
    }

    @Test func deleteLectureGoesToTrash() throws {
        try store.bootstrap()
        let lecture = try store.createLecture(subject: "Высшая алгебра", topic: "Матрицы", date: .d("2026-10-14"))
        try store.deleteLecture(id: lecture.id)
        #expect(trasher.trashed == ["2026-10-14 — Матрицы"])
        #expect(try store.findLecture(id: lecture.id) == nil)
        #expect(throws: LibraryError.lectureNotFound) { try store.deleteLecture(id: lecture.id) }
    }

    // MARK: Недоступные лекции

    @Test func folderWithoutMetaIsIgnored() throws {
        try store.bootstrap()
        try FileManager.default.createDirectory(at: store.root.appendingPathComponent("Высшая алгебра/просто папка"),
                                                withIntermediateDirectories: true)
        let subject = try #require(try store.loadSubjects().first { $0.name == "Высшая алгебра" })
        #expect(subject.lectures.isEmpty && subject.unavailable.isEmpty)
    }

    @Test func evictedMetaShownAsDownloading() throws {
        try store.bootstrap()
        let folder = store.root.appendingPathComponent("Высшая алгебра/2026-10-14 — Матрицы")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent(".meta.json.icloud"))
        let subject = try #require(try store.loadSubjects().first { $0.name == "Высшая алгебра" })
        #expect(subject.unavailable.map(\.reason) == [.downloading])
    }

    @Test func brokenMetaShownAsUnreadable() throws {
        try store.bootstrap()
        let folder = store.root.appendingPathComponent("Высшая алгебра/сломанная")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{не json".utf8).write(to: folder.appendingPathComponent("meta.json"))
        let subject = try #require(try store.loadSubjects().first { $0.name == "Высшая алгебра" })
        guard case .unreadable = subject.unavailable.first?.reason else {
            Issue.record("Ожидалась нечитаемая лекция")
            return
        }
    }
}
