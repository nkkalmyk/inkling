import Foundation

/// Соседние лекции предмета по дате: «Лекция → Предыдущая / Следующая» (⌘[ ⌘]) и ссылки в конце конспекта.
/// Порядок тот же, что в списке лекций (дата, затем тема), только от ранних к поздним.
struct LectureNeighbors: Equatable, Sendable {
    struct Link: Equatable, Sendable, Encodable {
        var id: UUID
        var title: String
    }

    var previous: Link?
    var next: Link?

    static func find(_ id: UUID, in lectures: [LectureRecord]) -> LectureNeighbors {
        let ordered = lectures.sorted { ($0.meta.date, $0.meta.topic) < ($1.meta.date, $1.meta.topic) }
        guard let index = ordered.firstIndex(where: { $0.id == id }) else { return LectureNeighbors() }
        func link(_ position: Int) -> Link? {
            ordered.indices.contains(position) ? Link(id: ordered[position].id, title: ordered[position].meta.topic) : nil
        }
        return LectureNeighbors(previous: link(index - 1), next: link(index + 1))
    }
}

extension Library {
    /// Лекции предмета, к которому относится лекция.
    func subjectLectures(containing id: UUID) -> [LectureRecord] {
        subjects.first(where: { $0.lectures.contains { $0.id == id } })?.lectures ?? []
    }

    /// Соседи лекции внутри её предмета.
    func neighbors(of id: UUID) -> LectureNeighbors {
        LectureNeighbors.find(id, in: subjectLectures(containing: id))
    }

    /// Открывает лекцию на той же вкладке, что и текущая: переход из конспекта ведёт в конспект соседа.
    /// `anchor` — раздел конспекта (`sec-N`), к которому прокрутить.
    func openLecture(_ id: UUID, tab: LectureTab, anchor: String? = nil) {
        requestedTab = tab
        requestedAnchor = anchor
        selection = id
    }
}
