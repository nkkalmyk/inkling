import AppKit
import Foundation
import Testing
@testable import Inkling

@Suite("SourceImporter")
struct SourceImporterTests {
    let dir: TempDir
    let lectureFolder: URL
    let importer: SourceImporter

    init() throws {
        dir = try TempDir()
        lectureFolder = dir.url.appendingPathComponent("lecture")
        try FileManager.default.createDirectory(at: lectureFolder, withIntermediateDirectories: true)
        importer = SourceImporter(paths: LecturePaths(folder: lectureFolder))
    }

    private func input(_ name: String) -> URL { dir.url.appendingPathComponent(name) }

    @Test func importsPhotosSortedByCaptureDate() throws {
        let late = Fixtures.write(Fixtures.paperOnDesk(), to: input("late.jpg"), dateTimeOriginal: "2026:10:12 10:00:00")
        let none = Fixtures.write(Fixtures.halfRed(), to: input("none.png"), type: .png)
        let early = Fixtures.write(Fixtures.halfRed(), to: input("early.heic"), type: .heic,
                                   dateTimeOriginal: "2026:10:12 09:00:00")
        let progress = ProgressLog()
        let result = importer.importFiles([late, none, early], into: .notes) { done, total in
            progress.append(done)
            #expect(total == 3)
        }
        #expect(result.skipped.isEmpty)
        #expect(result.notes.count == 3)
        #expect(result.notes.map { $0.source.file.split(separator: ".").last! } == ["heic", "jpg", "png"])
        #expect(progress.values == [1, 2, 3])

        let paths = LecturePaths(folder: lectureFolder)
        for page in result.notes {
            #expect(FileManager.default.fileExists(atPath: paths.original(page.source, in: .notes).path))
            let photo = try Data(contentsOf: paths.notePhoto(page.id))
            #expect(photo.prefix(2) == Data([0xFF, 0xD8]))
        }
        // На фото листа документ найден и сохранён, на остальных — нет.
        let paper = try #require(result.notes.first { $0.source.file.hasSuffix(".jpg") })
        #expect(paper.crop.quad != nil)
    }

    @Test func notesPDFBecomesPagesWithoutAutoCrop() throws {
        let pdf = Fixtures.pdf(pages: [nil, nil], to: input("scan.pdf"))
        let result = importer.importFiles([pdf], into: .notes)
        #expect(result.notes.count == 2)
        #expect(result.notes.map(\.crop) == [.original, .original])
        #expect(Set(result.notes.map(\.source.file)).count == 1)
        #expect(result.notes.map(\.source) == [.pdfPage(file: result.notes[0].source.file, index: 0),
                                               .pdfPage(file: result.notes[0].source.file, index: 1)])
        for page in result.notes {
            #expect(FileManager.default.fileExists(atPath: LecturePaths(folder: lectureFolder).notePhoto(page.id).path))
        }
    }

    @Test func slidesPDFUsesTextLayerOrImage() throws {
        let pdf = Fixtures.pdf(pages: ["Основные понятия: окислитель принимает электроны, восстановитель отдаёт", nil],
                               to: input("Лекция 5: ОВР.pdf"))
        let result = importer.importFiles([pdf], into: .slides)
        #expect(result.slides.count == 2)
        let paths = LecturePaths(folder: lectureFolder)
        #expect(result.slides[0].source.file == "Лекция 5- ОВР.pdf")

        let text = result.slides[0]
        #expect(!text.usesImage)
        #expect(try String(contentsOf: paths.pageText(text.id, in: .slides), encoding: .utf8).contains("окислитель"))
        #expect(!FileManager.default.fileExists(atPath: paths.slideImage(text.id).path))

        let picture = result.slides[1]
        #expect(picture.usesImage && picture.heuristicReason == "нет текстового слоя")
        #expect(FileManager.default.fileExists(atPath: paths.slideImage(picture.id).path))
    }

    @Test func secondDeckWithSameNameGetsSuffix() throws {
        let pdf = Fixtures.pdf(pages: ["Слайд с текстом достаточной длины для текстового слоя"], to: input("deck.pdf"))
        let first = importer.importFiles([pdf], into: .slides)
        let second = importer.importFiles([pdf], into: .slides)
        #expect(first.slides[0].source.file == "deck.pdf")
        #expect(second.slides[0].source.file == "deck (2).pdf")
    }

    @Test func switchingSlideModeSyncsFiles() throws {
        let pdf = Fixtures.pdf(pages: ["Слайд с текстом достаточной длины для текстового слоя"], to: input("deck.pdf"))
        var slide = try #require(importer.importFiles([pdf], into: .slides).slides.first)
        let paths = LecturePaths(folder: lectureFolder)
        slide.mode = .image
        try importer.syncSlideFiles(slide)
        #expect(FileManager.default.fileExists(atPath: paths.slideImage(slide.id).path))
        slide.mode = .textLayer
        try importer.syncSlideFiles(slide)
        #expect(!FileManager.default.fileExists(atPath: paths.slideImage(slide.id).path))
    }

    @Test func unsupportedAndBrokenFilesAreSkipped() throws {
        let txt = input("notes.txt")
        try Data("текст".utf8).write(to: txt)
        let broken = input("broken.jpg")
        try Data("не картинка".utf8).write(to: broken)
        let result = importer.importFiles([txt, broken], into: .notes)
        #expect(result.notes.isEmpty)
        #expect(result.skipped.map(\.name) == ["notes.txt", "broken.jpg"])
        // Оригинал битой картинки не остаётся в папке лекции.
        let originals = LecturePaths(folder: lectureFolder).originalsFolder(.notes)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: originals.path)) ?? []).isEmpty)
    }

    @Test func rotationAndCropAreReappliedFromOriginal() throws {
        let photo = Fixtures.write(Fixtures.halfRed(width: 400, height: 200), to: input("a.jpg"))
        var page = try #require(importer.importFiles([photo], into: .notes).notes.first)
        page.crop = .original
        page.rotation = 1
        try importer.renderNotePhoto(page)
        let data = try Data(contentsOf: LecturePaths(folder: lectureFolder).notePhoto(page.id))
        let image = try #require(Fixtures.decode(data))
        #expect(image.width == 200 && image.height == 400)
    }

    @Test func filesToRemoveKeepsSharedOriginals() {
        let paths = LecturePaths(folder: lectureFolder)
        let shared = PageSource.pdfPage(file: "scan.pdf", index: 0)
        let own = PageSource.image(file: "p.jpg")
        let files = importer.filesToRemove(removed: [shared: ["a"], own: ["b"]], section: .notes,
                                           remainingSources: [.pdfPage(file: "scan.pdf", index: 1)])
        #expect(files.originals == [paths.original(own, in: .notes)])
        #expect(Set(files.derived) == Set([paths.notePhoto("a"), paths.notePhoto("b"),
                                          paths.pageText("a", in: .notes), paths.pageText("b", in: .notes)]))
    }
}

@Suite("Источники в meta.json")
struct LectureSourcesMetaTests {
    private func note(_ id: String, captured: String? = nil) -> NotePage {
        NotePage(id: id, source: .image(file: "\(id).jpg"),
                 captureDate: captured.flatMap { ISO8601DateFormatter().date(from: $0) },
                 crop: .auto(nil), addedAt: Date(timeIntervalSince1970: 0))
    }

    private func meta(date: String = "2026-10-14") -> LectureMeta {
        LectureMeta(subject: "Высшая алгебра", topic: "Матрицы", date: .d(date))
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func firstDatedPhotosAdjustDateOnce() {
        var m = meta()
        m.appendImported(ImportResult(notes: [note("a", captured: "2026-10-12T09:00:00Z"),
                                              note("b", captured: "2026-10-11T23:00:00Z")]), calendar: utc)
        #expect(m.date == .d("2026-10-11"))
        #expect(m.dateAdjustment == DateAdjustment(previousDate: .d("2026-10-14")))
        #expect(m.dateAutoAdjusted)

        m.acceptDateAdjustment()
        m.appendImported(ImportResult(notes: [note("c", captured: "2026-09-01T09:00:00Z")]), calendar: utc)
        #expect(m.date == .d("2026-10-11"))
        #expect(m.dateAdjustment == nil)
        #expect(m.notes.map(\.id) == ["c", "b", "a"], "Страницы стоят по времени снимка")
    }

    @Test func sameDayPhotosDoNotShowBanner() {
        var m = meta()
        m.appendImported(ImportResult(notes: [note("a", captured: "2026-10-14T09:00:00Z")]), calendar: utc)
        #expect(m.date == .d("2026-10-14"))
        #expect(m.dateAdjustment == nil)
        #expect(m.dateAutoAdjusted)
    }

    @Test func undatedPhotosDoNotConsumeAdjustment() {
        var m = meta()
        m.appendImported(ImportResult(notes: [note("a")]), calendar: utc)
        #expect(!m.dateAutoAdjusted)
        m.appendImported(ImportResult(notes: [note("b", captured: "2026-10-10T09:00:00Z")]), calendar: utc)
        #expect(m.date == .d("2026-10-10"))
    }

    @Test func revertRestoresPreviousDate() {
        var m = meta()
        m.appendImported(ImportResult(notes: [note("a", captured: "2026-10-10T09:00:00Z")]), calendar: utc)
        m.revertDateAdjustment()
        #expect(m.date == .d("2026-10-14"))
        #expect(m.dateAdjustment == nil)
        #expect(m.dateAutoAdjusted)
    }

    @Test func moveAndInsertionPoint() {
        var m = meta()
        m.notes = ["a", "b", "c", "d"].map { note($0) }
        m.movePages(["d"], before: "b", in: .notes)
        #expect(m.notes.map(\.id) == ["a", "d", "b", "c"])
        m.movePages(["a", "b"], before: nil, in: .notes)
        #expect(m.notes.map(\.id) == ["d", "c", "a", "b"])
        m.movePages(["zzz"], before: "a", in: .notes)
        #expect(m.notes.map(\.id) == ["d", "c", "a", "b"])

        let order = ["a", "b", "c", "d"]
        #expect(LectureMeta.insertionPoint(order: order, dragged: ["a"], droppedOn: "c") == "d")
        #expect(LectureMeta.insertionPoint(order: order, dragged: ["a"], droppedOn: "d") == nil)
        #expect(LectureMeta.insertionPoint(order: order, dragged: ["d"], droppedOn: "b") == "b")
    }

    @Test func removeGroupsBySource() {
        var m = meta()
        m.notes = [note("a"), note("b")]
        m.notes[1].source = .pdfPage(file: "scan.pdf", index: 0)
        let removed = m.removePages(["b"], in: .notes)
        #expect(removed == [.pdfPage(file: "scan.pdf", index: 0): ["b"]])
        #expect(m.notes.map(\.id) == ["a"])
    }

    @Test func rotationWraps() {
        var m = meta()
        m.notes = [note("a")]
        #expect(m.rotateNote("a", by: -1)?.rotation == 3)
        #expect(m.rotateNote("a", by: 2)?.rotation == 1)
        #expect(m.rotateNote("нет", by: 1) == nil)
    }

    @Test func slideUsesImage() {
        var slide = SlidePage(id: "s", source: .pdfPage(file: "d.pdf", index: 0), heuristicNeedsImage: false,
                              addedAt: Date())
        #expect(!slide.usesImage)
        slide.heuristicNeedsImage = true
        #expect(slide.usesImage)
        slide.mode = .textLayer
        #expect(!slide.usesImage)
        slide.source = .image(file: "s.png")
        #expect(slide.usesImage)
    }

    @Test func metaWithPagesRoundTrips() throws {
        var m = meta()
        m.notes = [note("a", captured: "2026-10-12T09:00:00Z")]
        m.notes[0].crop = .manual(Quad(topLeft: .init(x: 0, y: 1), topRight: .init(x: 1, y: 1),
                                       bottomRight: .init(x: 1, y: 0), bottomLeft: .zero))
        m.slides = [SlidePage(id: "s", source: .pdfPage(file: "d.pdf", index: 2), heuristicNeedsImage: true,
                              heuristicReason: "формулы", excluded: true, addedAt: Date(timeIntervalSince1970: 0))]
        m.dateAdjustment = DateAdjustment(previousDate: .d("2026-01-01"))
        let data = try JSONCoding.makeEncoder().encode(m)
        #expect(try JSONCoding.makeDecoder().decode(LectureMeta.self, from: data) == m)
    }
}

@Suite("Перенос лекции при смене даты")
struct MutateLectureTests {
    @Test func dateChangeFromPhotosRenamesFolder() throws {
        let dir = try TempDir()
        let store = LibraryStore(root: dir.url.appendingPathComponent("Inkling"),
                                 trasher: try FakeTrasher(bin: dir.url.appendingPathComponent("_bin")))
        try store.bootstrap()
        let lecture = try store.createLecture(subject: "Высшая алгебра", topic: "Матрицы", date: .d("2026-10-14"))
        let updated = try store.mutateLecture(id: lecture.id) { $0.date = .d("2026-10-12") }
        #expect(updated.folder.lastPathComponent == "2026-10-12 — Матрицы")
        #expect(try store.readMeta(in: updated.folder).date == .d("2026-10-12"))
    }
}

@Suite("Буфер обмена")
@MainActor
struct PasteboardImportTests {
    @Test func imageDataBecomesFile() throws {
        let dir = try TempDir()
        let pasteboard = NSPasteboard(name: .init("InklingTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let png = NSBitmapImageRep(cgImage: Fixtures.halfRed()).representation(using: .png, properties: [:])!
        pasteboard.setData(png, forType: .png)
        let urls = ImportStaging.files(from: pasteboard, staging: dir.url)
        #expect(urls.count == 1)
        #expect(urls.first?.pathExtension == "png")
        #expect(try Data(contentsOf: urls[0]) == png)
    }

    @Test func fileURLsArePassedThrough() throws {
        let dir = try TempDir()
        let file = Fixtures.write(Fixtures.halfRed(), to: dir.url.appendingPathComponent("a.jpg"))
        let pasteboard = NSPasteboard(name: .init("InklingTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        #expect(ImportStaging.files(from: pasteboard, staging: dir.url).map(\.lastPathComponent) == ["a.jpg"])
    }

    @Test func emptyPasteboardGivesNothing() throws {
        let dir = try TempDir()
        let pasteboard = NSPasteboard(name: .init("InklingTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("просто текст", forType: .string)
        #expect(ImportStaging.files(from: pasteboard, staging: dir.url).isEmpty)
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []

    var values: [Int] { lock.withLock { storage } }

    func append(_ value: Int) { lock.withLock { storage.append(value) } }
}

@Suite("Порядок по времени снимка")
struct ShotOrderTests {
    private let moscow = TimeZone(identifier: "Europe/Moscow")!
    private func iso(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    @Test(arguments: [
        ("Снимок экрана 2026-10-14 в 12.30.45", "2026-10-14T09:30:45Z"),
        ("Screenshot 2026-10-14 at 12.30.45 PM", "2026-10-14T09:30:45Z"),
        ("Screenshot 2026-10-14 at 12.05.09 AM", "2026-10-13T21:05:09Z"),
        ("IMG_20261014_123045", "2026-10-14T09:30:45Z"),
        ("PXL_20261014_123045123", "2026-10-14T09:30:45Z"),
        ("2026-10-14 12-30-45", "2026-10-14T09:30:45Z"),
    ])
    func dateFromFileName(_ name: String, _ expected: String) {
        #expect(ImageProcessor.dateFromFileName(name, timeZone: moscow) == iso(expected))
    }

    @Test(arguments: ["IMG_0042", "лекция 5", "2026-13-40 99.99.99", "scan"])
    func noDateInName(_ name: String) {
        #expect(ImageProcessor.dateFromFileName(name, timeZone: moscow) == nil)
    }

    private func page(_ id: String, _ date: String?) -> NotePage {
        NotePage(id: id, source: .image(file: "\(id).png"), captureDate: date.map(iso), crop: .original, addedAt: Date())
    }

    @Test func newPagesInsertBetweenExisting() {
        let existing = [page("a", "2026-10-14T09:00:00Z"), page("c", "2026-10-14T11:00:00Z"), page("scan", nil)]
        let added = [page("d", "2026-10-14T12:00:00Z"), page("b", "2026-10-14T10:00:00Z"),
                     page("z", "2026-10-14T08:00:00Z"), page("pdf", nil)]
        let merged = LectureMeta.mergedByShotTime(existing, added)
        #expect(merged.map(\.id) == ["z", "a", "b", "c", "scan", "d", "pdf"])
    }

    @Test func screenshotWithoutExifUsesFileName() throws {
        let dir = try TempDir()
        let lecture = dir.url.appendingPathComponent("lecture")
        let late = Fixtures.write(Fixtures.halfRed(), to: dir.url.appendingPathComponent("Снимок экрана 2026-10-14 в 12.30.45.png"),
                                  type: .png)
        let early = Fixtures.write(Fixtures.halfRed(), to: dir.url.appendingPathComponent("Снимок экрана 2026-10-14 в 09.00.00.png"),
                                   type: .png)
        let result = SourceImporter(paths: LecturePaths(folder: lecture)).importFiles([late, early], into: .notes)
        #expect(result.notes.count == 2)
        #expect(result.notes[0].captureDate! < result.notes[1].captureDate!)
        #expect(Calendar.current.component(.hour, from: result.notes[0].captureDate!) == 9)
    }
}
