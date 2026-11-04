import AppKit
import Observation
import PDFKit

/// Предмет целиком одним файлом (SPEC, раздел 13): лекции по дате, у каждой свой титул, в начале — оглавление.
/// PDF склеивается из PDF лекций (те же титулы, колонтитулы и переходы, что у одиночного экспорта), HTML собирается
/// `HTMLExporter` из отрисованных конспектов. Лекции без конспекта пропускаются и перечисляются после экспорта.
@MainActor
@Observable
final class SubjectExportCenter {
    enum Kind: String { case pdf = "PDF", html = "HTML" }

    struct Run: Equatable {
        var subject: String
        var kind: Kind
        var done: Int
        var total: Int
        var startedAt: Date
    }

    /// Итог последнего экспорта: файл и лекции, которые не вошли.
    struct Result: Equatable {
        var subject: String
        var url: URL
        var skipped: [String]
    }

    private(set) var run: Run?
    var result: Result?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let library: Library

    init(library: Library) { self.library = library }

    func cancel() { task?.cancel() }

    func export(_ subject: SubjectRecord, as kind: Kind) {
        guard run == nil else { return }
        let ordered = Self.ordered(subject.lectures)
        let base = "\(FolderNaming.sanitize(subject.name)) — все лекции — \(CalendarDate.today)"
        let url: URL
        do {
            url = kind == .pdf ? try ExportLocation.pdfURL(baseName: base, subject: subject.name)
                : try ExportLocation.htmlURL(baseName: base, subject: subject.name)
        } catch {
            library.errorMessage = "Не удалось создать папку «\(ExportLocation.pdfFolderName)/"
                + "\(ExportLocation.subjectFolderName(subject.name))»: \(error.localizedDescription)"
            return
        }
        result = nil
        run = Run(subject: subject.name, kind: kind, done: 0, total: ordered.count, startedAt: .now)
        task = Task {
            defer { run = nil; task = nil }
            do {
                let (parts, skipped) = await Self.read(ordered)
                guard !parts.isEmpty else {
                    library.errorMessage = "В предмете «\(subject.name)» нет лекций с собранным конспектом."
                    return
                }
                run?.total = parts.count
                switch kind {
                case .pdf: try await exportPDF(parts, subject: subject.name, to: url)
                case .html: try await exportHTML(parts, subject: subject.name, to: url)
                }
                result = Result(subject: subject.name, url: url, skipped: skipped)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch is CancellationError {
                return
            } catch {
                library.errorMessage = error.localizedDescription
            }
        }
    }

    /// Лекции по дате, затем по теме — как в списке, только от ранних к поздним.
    nonisolated static func ordered(_ lectures: [LectureRecord]) -> [LectureRecord] {
        lectures.sorted { ($0.meta.date, $0.meta.topic) < ($1.meta.date, $1.meta.topic) }
    }

    struct Part: Sendable {
        var lecture: LectureRecord
        var markdown: String
    }

    /// Конспекты в фоне; лекции без конспекта или с выгруженным в iCloud файлом не входят.
    @concurrent
    private static func read(_ lectures: [LectureRecord]) async -> ([Part], [String]) {
        var parts: [Part] = []
        var skipped: [String] = []
        for lecture in lectures {
            let store = KonspektStore(folder: lecture.folder)
            if lecture.meta.konspekt != nil, ICloud.availability(of: store.url) == .local, let markdown = store.read() {
                parts.append(Part(lecture: lecture, markdown: markdown))
            } else {
                skipped.append(lecture.meta.topic)
            }
        }
        return (parts, skipped)
    }

    private func heading(_ lecture: LectureRecord) -> PrintHeading {
        PrintHeading(subject: lecture.meta.subject, topic: lecture.meta.topic, date: lecture.meta.date.formatted)
    }

    private func exportHTML(_ parts: [Part], subject: String, to url: URL) async throws {
        var sections: [HTMLExporter.Section] = []
        for (index, part) in parts.enumerated() {
            try Task.checkCancellation()
            let rendered = try await NotesRenderer().render(markdown: part.markdown, heading: heading(part.lecture))
            sections.append(.init(id: "l\(index + 1)", title: part.lecture.meta.topic, rendered: rendered))
            run?.done = index + 1
        }
        try HTMLExporter.write(title: "\(subject) — все лекции", sections: sections, toc: true, to: url)
    }

    /// Каждая лекция печатается отдельно (во временную папку), затем файлы склеиваются: одно большое окно печати
    /// на десятки лекций держало бы в памяти всю вёрстку сразу.
    private func exportPDF(_ parts: [Part], subject: String, to url: URL) async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("Inkling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        var files: [(title: String, url: URL)] = []
        for (index, part) in parts.enumerated() {
            try Task.checkCancellation()
            let file = temp.appendingPathComponent("\(index + 1).pdf")
            try await PDFExporter().export(markdown: part.markdown, title: part.lecture.meta.topic,
                                           heading: heading(part.lecture), to: file)
            files.append((part.lecture.meta.topic, file))
            run?.done = index + 1
        }
        try PDFMerger.merge(files, title: "\(subject) — все лекции", to: url)
    }
}

/// Склейка PDF лекций в один файл. Переходы внутри лекции (оглавление) и закладки перенаправляются на страницы
/// общего файла: иначе они указывали бы на страницы исходных файлов. В закладках у каждой лекции свой пункт,
/// под ним — её разделы.
enum PDFMerger {
    static func merge(_ parts: [(title: String, url: URL)], title: String, to url: URL) throws {
        let merged = PDFDocument()
        let root = PDFOutline()
        for part in parts {
            guard let source = PDFDocument(url: part.url) else { throw PDFExportError.printFailed }
            let offset = merged.pageCount
            for index in 0..<source.pageCount {
                guard let page = source.page(at: index)?.copy() as? PDFPage else { continue }
                merged.insert(page, at: merged.pageCount)
            }
            func target(_ destination: PDFDestination?) -> PDFDestination? {
                guard let destination, let page = destination.page else { return nil }
                let index = source.index(for: page)
                guard index != NSNotFound, let newPage = merged.page(at: offset + index) else { return nil }
                return PDFDestination(page: newPage, at: destination.point)
            }
            for index in 0..<source.pageCount {
                guard let original = source.page(at: index), let copy = merged.page(at: offset + index) else { continue }
                let originals = original.annotations
                for (position, annotation) in copy.annotations.enumerated() where position < originals.count {
                    let from = originals[position]
                    let destination = from.destination ?? (from.action as? PDFActionGoTo)?.destination
                    guard let retargeted = target(destination) else { continue }
                    annotation.action = PDFActionGoTo(destination: retargeted)
                }
            }
            let lecture = PDFOutline()
            lecture.label = part.title
            if let first = merged.page(at: offset) { lecture.destination = PDFDestination(page: first, at: CGPoint(x: 0, y: first.bounds(for: .mediaBox).maxY)) }
            if let outline = source.outlineRoot { copyOutline(outline, into: lecture, target: target) }
            root.insertChild(lecture, at: root.numberOfChildren)
        }
        merged.outlineRoot = root
        merged.documentAttributes = [PDFDocumentAttribute.titleAttribute: title, PDFDocumentAttribute.creatorAttribute: "Inkling"]
        try? FileManager.default.removeItem(at: url)
        guard merged.write(to: url) else { throw PDFExportError.printFailed }
    }

    private static func copyOutline(_ source: PDFOutline, into parent: PDFOutline, target: (PDFDestination?) -> PDFDestination?) {
        for index in 0..<source.numberOfChildren {
            guard let child = source.child(at: index) else { continue }
            let copy = PDFOutline()
            copy.label = child.label
            copy.destination = target(child.destination ?? (child.action as? PDFActionGoTo)?.destination)
            copyOutline(child, into: copy, target: target)
            parent.insertChild(copy, at: parent.numberOfChildren)
        }
    }
}
