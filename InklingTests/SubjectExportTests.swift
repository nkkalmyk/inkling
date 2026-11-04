import Foundation
import PDFKit
import Testing
@testable import Inkling

@Suite("Экспорт предмета целиком")
struct SubjectExportTests {
    @Test func lecturesGoByDateThenTopic() {
        func lecture(_ topic: String, _ date: String) -> LectureRecord {
            LectureRecord(meta: LectureMeta(subject: "Алгебра", topic: topic, date: .d(date)), folder: URL(filePath: "/tmp/\(topic)"))
        }
        let ordered = SubjectExportCenter.ordered([lecture("Б", "2026-10-20"), lecture("В", "2026-10-13"), lecture("А", "2026-10-20")])
        #expect(ordered.map(\.meta.topic) == ["В", "А", "Б"])
    }

    /// PDF лекции с переходом из оглавления (стр. 1 → стр. 2) и закладкой на раздел. Страницы копируются в новый
    /// документ: в PDF, открытый из файла CoreGraphics, PDFKit закладки не сохраняет (проверено).
    private func lecturePDF(_ name: String, in dir: TempDir) throws -> URL {
        let plain = Fixtures.pdf(pages: ["Оглавление \(name)", "Раздел \(name)"], to: dir.url.appendingPathComponent("\(name).pdf"))
        let source = try #require(PDFDocument(url: plain))
        let document = PDFDocument()
        for index in 0..<source.pageCount {
            document.insert(try #require(source.page(at: index)?.copy() as? PDFPage), at: document.pageCount)
        }
        let first = try #require(document.page(at: 0)), second = try #require(document.page(at: 1))
        let link = PDFAnnotation(bounds: CGRect(x: 40, y: 400, width: 200, height: 30), forType: .link, withProperties: nil)
        link.action = PDFActionGoTo(destination: PDFDestination(page: second, at: CGPoint(x: 0, y: 500)))
        first.addAnnotation(link)
        let root = PDFOutline(), section = PDFOutline()
        section.label = "Раздел \(name)"
        section.destination = PDFDestination(page: second, at: CGPoint(x: 0, y: 500))
        root.insertChild(section, at: 0)
        document.outlineRoot = root
        let out = dir.url.appendingPathComponent("\(name)-с-переходами.pdf")
        #expect(document.write(to: out))
        return out
    }

    @Test func mergeRetargetsLinksAndBookmarks() throws {
        let dir = try TempDir()
        let out = dir.url.appendingPathComponent("Алгебра — все лекции.pdf")
        try PDFMerger.merge([("Матрицы", try lecturePDF("A", in: dir)), ("Миноры", try lecturePDF("B", in: dir))],
                            title: "Алгебра — все лекции", to: out)
        let merged = try #require(PDFDocument(url: out))
        #expect(merged.pageCount == 4)

        let root = try #require(merged.outlineRoot)
        #expect(root.numberOfChildren == 2)
        let second = try #require(root.child(at: 1))
        #expect(second.label == "Миноры")
        #expect(second.destination.flatMap { $0.page }.map { merged.index(for: $0) } == 2, "лекция начинается со своей страницы")
        let section = try #require(second.child(at: 0))
        #expect(section.label == "Раздел B")
        #expect(section.destination.flatMap { $0.page }.map { merged.index(for: $0) } == 3, "закладка раздела — на стр. 4 общего файла")

        let link = try #require(merged.page(at: 2)?.annotations.first)
        let target = (link.action as? PDFActionGoTo)?.destination ?? link.destination
        #expect(target.flatMap { $0.page }.map { merged.index(for: $0) } == 3, "переход из оглавления второй лекции — на её раздел")
        #expect(merged.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Алгебра — все лекции")
    }
}
