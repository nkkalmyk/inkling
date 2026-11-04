import Foundation
import Testing
@testable import Inkling

@Suite("Соседние лекции")
struct LectureNeighborsTests {
    private func lecture(_ topic: String, _ date: String) -> LectureRecord {
        LectureRecord(meta: LectureMeta(subject: "Алгебра", topic: topic, date: .d(date)), folder: URL(filePath: "/tmp/\(topic)"))
    }

    @Test func orderByDateThenTopic() {
        let first = lecture("Матрицы", "2026-10-13"), second = lecture("Блочные", "2026-10-16")
        let sameDayA = lecture("Миноры", "2026-10-20"), sameDayB = lecture("Обратная", "2026-10-20")
        let lectures = [sameDayB, first, sameDayA, second]

        let middle = LectureNeighbors.find(sameDayA.id, in: lectures)
        #expect(middle.previous?.id == second.id)
        #expect(middle.next?.id == sameDayB.id, "в один день — по теме")
        #expect(middle.next?.title == "Обратная")

        #expect(LectureNeighbors.find(first.id, in: lectures).previous == nil, "у первой нет предыдущей")
        #expect(LectureNeighbors.find(sameDayB.id, in: lectures).next == nil, "у последней нет следующей")
    }

    @Test func singleOrMissingLecture() {
        let only = lecture("Единственная", "2026-10-13")
        #expect(LectureNeighbors.find(only.id, in: [only]) == LectureNeighbors())
        #expect(LectureNeighbors.find(UUID(), in: [only]) == LectureNeighbors())
    }

    @Test func lectureLinksAreParsedOnlyFromOwnScheme() throws {
        let id = UUID()
        #expect(NotesWebView.Coordinator.lectureID(try #require(URL(string: "inkling-lecture://\(id.uuidString.lowercased())"))) == id)
        #expect(NotesWebView.Coordinator.lectureID(try #require(URL(string: "inkling-lecture://не-uuid"))) == nil)
        #expect(NotesWebView.Coordinator.lectureID(try #require(URL(string: "https://\(id.uuidString)"))) == nil)
        #expect(!NotesWebView.Coordinator.opensExternally(try #require(URL(string: "inkling-lecture://\(id)"))))
    }
}
