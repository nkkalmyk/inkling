import Foundation
import Testing
@testable import Inkling

@Suite("CalendarDate")
struct CalendarDateTests {
    @Test func parsesAndFormats() throws {
        let date = try #require(CalendarDate(string: "2026-03-07"))
        #expect(date == CalendarDate(year: 2026, month: 3, day: 7))
        #expect(date.description == "2026-03-07")
    }

    @Test(arguments: ["2026-02-30", "2026-13-01", "26-01-01", "2026-1-01", "2026/01/01", "", "abcd-ef-gh"])
    func rejectsInvalid(_ raw: String) {
        #expect(CalendarDate(string: raw) == nil)
    }

    @Test func roundTripsThroughJSONAsString() throws {
        let data = try JSONCoding.makeEncoder().encode(["d": CalendarDate.d("2024-02-29")])
        #expect(String(decoding: data, as: UTF8.self).contains("\"2024-02-29\""))
        let back = try JSONCoding.makeDecoder().decode([String: CalendarDate].self, from: data)
        #expect(back["d"] == .d("2024-02-29"))
    }

    @Test func conversionKeepsDayInAnyTimeZone() {
        for zone in ["Pacific/Kiritimati", "Pacific/Pago_Pago", "Europe/Moscow"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!
            let day = CalendarDate.d("2026-10-14")
            #expect(CalendarDate(day.date(calendar: calendar), calendar: calendar) == day)
        }
    }

    @Test func ordering() {
        #expect(CalendarDate.d("2026-01-31") < .d("2026-02-01"))
        #expect(CalendarDate.d("2025-12-31") < .d("2026-01-01"))
    }
}

@Suite("LectureMeta")
struct LectureMetaTests {
    @Test func roundTrip() throws {
        let meta = LectureMeta(subject: "Высшая алгебра", topic: "Матрицы", date: .d("2026-10-14"),
                               now: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try JSONCoding.makeEncoder().encode(meta)
        let back = try JSONCoding.makeDecoder().decode(LectureMeta.self, from: data)
        #expect(back == meta)
        #expect(back.schemaVersion == LectureMeta.currentSchemaVersion)
    }

    @Test func toleratesMissingOptionalAndUnknownFields() throws {
        let json = """
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","date":"2026-10-14","topic":"Пределы",
         "futureField":{"x":1}}
        """
        let meta = try JSONCoding.makeDecoder().decode(LectureMeta.self, from: Data(json.utf8))
        #expect(meta.topic == "Пределы")
        #expect(meta.subject == "")
        #expect(meta.schemaVersion == 1)
    }

    @Test func requiresIdAndDate() {
        let json = #"{"topic":"Без id","date":"2026-10-14"}"#
        #expect(throws: DecodingError.self) {
            try JSONCoding.makeDecoder().decode(LectureMeta.self, from: Data(json.utf8))
        }
    }
}

@Suite("AtomicFile")
struct AtomicFileTests {
    @Test func writesAndOverwritesWithoutLeftovers() throws {
        let dir = try TempDir()
        let file = dir.url.appendingPathComponent("meta.json")
        try AtomicFile.write(Data("один".utf8), to: file)
        try AtomicFile.write(Data("два".utf8), to: file)
        #expect(String(decoding: try AtomicFile.read(file), as: UTF8.self) == "два")
        #expect(dir.contents() == ["meta.json"])
    }

    @Test func failedEncodingKeepsOriginal() throws {
        struct Bad: Encodable {
            func encode(to encoder: Encoder) throws { throw EncodingError.invalidValue(0, .init(codingPath: [], debugDescription: "")) }
        }
        let dir = try TempDir()
        let file = dir.url.appendingPathComponent("meta.json")
        try AtomicFile.write(Data("исходный".utf8), to: file)
        #expect(throws: EncodingError.self) { try AtomicFile.writeJSON(Bad(), to: file) }
        #expect(String(decoding: try AtomicFile.read(file), as: UTF8.self) == "исходный")
        #expect(dir.contents() == ["meta.json"])
    }

    @Test func writeIntoMissingFolderFailsAndCreatesNothing() throws {
        let dir = try TempDir()
        let file = dir.url.appendingPathComponent("нет/meta.json")
        #expect(throws: (any Error).self) { try AtomicFile.write(Data("x".utf8), to: file) }
        #expect(dir.contents().isEmpty)
    }

    @Test func jsonEndsWithNewlineAndIsReadable() throws {
        let dir = try TempDir()
        let file = dir.url.appendingPathComponent("a.json")
        try AtomicFile.writeJSON(["путь": "a/b"], to: file)
        let text = String(decoding: try AtomicFile.read(file), as: UTF8.self)
        #expect(text.hasSuffix("\n"))
        #expect(text.contains("a/b"))
        #expect(try AtomicFile.readJSON([String: String].self, from: file) == ["путь": "a/b"])
    }
}

@Suite("FolderNaming")
struct FolderNamingTests {
    @Test(arguments: [
        ("Тема/подтема: часть 1", "Тема-подтема- часть 1"),
        ("  пробелы  ", "пробелы"),
        ("...скрытая", "скрытая"),
        ("", FolderNaming.untitled),
        ("   ", FolderNaming.untitled),
        ("две\nстроки", "две строки"),
    ])
    func sanitize(_ input: String, _ expected: String) {
        #expect(FolderNaming.sanitize(input) == expected)
    }

    @Test func sanitizeLimitsLength() {
        #expect(FolderNaming.sanitize(String(repeating: "я", count: 500)).count == FolderNaming.maxNameLength)
    }

    @Test func sanitizeNormalizesUnicode() {
        let decomposed = "Йод".decomposedStringWithCanonicalMapping
        #expect(FolderNaming.sanitize(decomposed).unicodeScalars.count == "Йод".precomposedStringWithCanonicalMapping.unicodeScalars.count)
    }

    @Test func lectureFolderName() {
        #expect(FolderNaming.lectureFolderName(date: .d("2026-10-14"), topic: "ОВР: основы")
            == "2026-10-14 — ОВР- основы")
    }

    @Test func uniqueURLAddsSuffixes() {
        let dir = URL(fileURLWithPath: "/x")
        let taken: Set<String> = ["/x/Тема", "/x/Тема (2)"]
        let url = FolderNaming.uniqueURL(in: dir, baseName: "Тема", exists: { taken.contains($0.path) })
        #expect(url.lastPathComponent == "Тема (3)")
    }

    @Test func uniqueURLTreatsExcludedAsFree() {
        let dir = URL(fileURLWithPath: "/x")
        let url = FolderNaming.uniqueURL(in: dir, baseName: "тема", excluding: URL(fileURLWithPath: "/x/Тема"),
                                         exists: { _ in true })
        #expect(url.lastPathComponent == "тема")
    }
}

@Suite("ICloud")
struct ICloudTests {
    @Test func placeholderNames() {
        #expect(ICloud.placeholderName(for: "meta.json") == ".meta.json.icloud")
        #expect(ICloud.originalName(fromPlaceholder: ".meta.json.icloud") == "meta.json")
        #expect(ICloud.originalName(fromPlaceholder: "meta.json") == nil)
        #expect(ICloud.originalName(fromPlaceholder: ".icloud") == nil)
    }

    @Test func availabilityDetectsPlaceholder() throws {
        let dir = try TempDir()
        let file = dir.url.appendingPathComponent("meta.json")
        #expect(ICloud.availability(of: file) == .missing)
        try Data().write(to: dir.url.appendingPathComponent(".meta.json.icloud"))
        #expect(ICloud.availability(of: file) == .notDownloaded)
        try Data("{}".utf8).write(to: file)
        #expect(ICloud.availability(of: file) == .local)
    }

    @Test func localFileHasNoConflicts() throws {
        let dir = try TempDir()
        let file = dir.url.appendingPathComponent("meta.json")
        try Data("{}".utf8).write(to: file)
        #expect(!ICloud.hasConflicts(file))
    }
}

@Suite("Приложение")
@MainActor
struct AppEnvironmentTests {
    @Test func detectsTestRun() {
        // Иначе тестовый запуск открыл бы настоящую папку ~/Documents/Inkling.
        #expect(InklingApp.isRunningTests)
    }
}

@Suite("meta.json: небезопасные пути страниц")
struct UnsafePagePathTests {
    @Test func pagesWithTraversalAreDropped() throws {
        let json = """
        {"id":"\(UUID().uuidString)","date":"2026-10-15","subject":"П","topic":"Т","notes":[
          {"id":"../../../Documents/x","source":{"image":{"file":"ok.jpg"}},"crop":{"original":{}},"rotation":0,"addedAt":"2026-10-15T10:00:00Z"},
          {"id":"good-1","source":{"image":{"file":"../../secret.docx"}},"crop":{"original":{}},"rotation":0,"addedAt":"2026-10-15T10:00:00Z"},
          {"id":"good-2","source":{"image":{"file":"ok.jpg"}},"crop":{"original":{}},"rotation":0,"addedAt":"2026-10-15T10:00:00Z"}]}
        """
        let meta = try JSONCoding.makeDecoder().decode(LectureMeta.self, from: Data(json.utf8))
        #expect(meta.notes.map(\.id) == ["good-2"])
    }

    @Test func generatedIDsAreSafe() {
        #expect(PageID.isSafe(PageID.make()))
        #expect(!PageID.isSafe("a/b") && !PageID.isSafe("..") && !PageID.isSafe(""))
    }
}
