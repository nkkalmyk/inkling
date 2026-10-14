import Foundation

/// Изменения списка источников в `meta.json`. Только данные: файлы меняет `SourceImporter`.
extension LectureMeta {
    /// Добавляет импортированные страницы в конец разделов. Если это первые фото с датой съёмки
    /// и дата лекции ещё не подстраивалась, дата меняется на день самого раннего снимка (SPEC, раздел 13).
    mutating func appendImported(_ result: ImportResult, calendar: Calendar = .current) {
        let hadDatedPhotos = notes.contains { $0.captureDate != nil }
        notes += result.notes
        slides += result.slides

        guard !dateAutoAdjusted, !hadDatedPhotos,
              let earliest = result.notes.compactMap(\.captureDate).min() else { return }
        dateAutoAdjusted = true
        let day = CalendarDate(earliest, calendar: calendar)
        if day != date {
            dateAdjustment = DateAdjustment(previousDate: date)
            date = day
        }
    }

    /// «Вернуть»: прежняя дата, плашка скрывается.
    mutating func revertDateAdjustment() {
        guard let adjustment = dateAdjustment else { return }
        date = adjustment.previousDate
        dateAdjustment = nil
    }

    /// Скрыть плашку, оставив новую дату.
    mutating func acceptDateAdjustment() {
        dateAdjustment = nil
    }

    /// Переставляет страницы `ids` (в их текущем порядке) перед страницей `target`; `nil` — в конец раздела.
    /// Страницы другого раздела игнорируются.
    mutating func movePages(_ ids: [String], before target: String?, in section: SourceSection) {
        switch section {
        case .notes: notes = Self.moving(notes, ids: ids, before: target)
        case .slides: slides = Self.moving(slides, ids: ids, before: target)
        }
    }

    /// Куда вставить перетаскиваемые страницы, брошенные на страницу `target`: если их тащили сверху вниз —
    /// после неё, иначе — перед ней. Возвращает id страницы, перед которой вставлять (`nil` — в конец).
    static func insertionPoint(order: [String], dragged: [String], droppedOn target: String) -> String? {
        guard let targetIndex = order.firstIndex(of: target),
              let firstDragged = order.firstIndex(where: { dragged.contains($0) }) else { return target }
        guard firstDragged < targetIndex else { return target }
        let draggedSet = Set(dragged)
        return order[(targetIndex + 1)...].first { !draggedSet.contains($0) }
    }

    static func moving<T: Identifiable>(_ items: [T], ids: [String], before target: String?) -> [T] where T.ID == String {
        let moving = Set(ids)
        guard !moving.isEmpty, target.map({ !moving.contains($0) }) ?? true else { return items }
        let moved = items.filter { moving.contains($0.id) }
        var rest = items.filter { !moving.contains($0.id) }
        let index = target.flatMap { t in rest.firstIndex { $0.id == t } } ?? rest.endIndex
        rest.insert(contentsOf: moved, at: index)
        return rest
    }

    /// Убирает страницы. Возвращает удалённые страницы, сгруппированные по источнику, для очистки файлов.
    mutating func removePages(_ ids: Set<String>, in section: SourceSection) -> [PageSource: [String]] {
        var removed: [PageSource: [String]] = [:]
        switch section {
        case .notes:
            for page in notes where ids.contains(page.id) { removed[page.source, default: []].append(page.id) }
            notes.removeAll { ids.contains($0.id) }
        case .slides:
            for page in slides where ids.contains(page.id) { removed[page.source, default: []].append(page.id) }
            slides.removeAll { ids.contains($0.id) }
        }
        return removed
    }

    func sources(in section: SourceSection) -> [PageSource] {
        switch section {
        case .notes: notes.map(\.source)
        case .slides: slides.map(\.source)
        }
    }

    /// Поворот фото рукописи на четверть оборота: `+1` — по часовой, `-1` — против.
    mutating func rotateNote(_ id: String, by quarterTurns: Int) -> NotePage? {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return nil }
        notes[i].rotation = (((notes[i].rotation + quarterTurns) % 4) + 4) % 4
        return notes[i]
    }

    mutating func setCrop(_ crop: CropMode, forNote id: String) -> NotePage? {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return nil }
        notes[i].crop = crop
        return notes[i]
    }

    mutating func setSlideMode(_ mode: SlideMode, for id: String) -> SlidePage? {
        guard let i = slides.firstIndex(where: { $0.id == id }) else { return nil }
        slides[i].mode = mode
        return slides[i]
    }

    mutating func setSlideExcluded(_ excluded: Bool, for id: String) {
        guard let i = slides.firstIndex(where: { $0.id == id }) else { return }
        slides[i].excluded = excluded
    }
}
