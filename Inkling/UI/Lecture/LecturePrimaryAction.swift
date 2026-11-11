import SwiftUI

// MARK: Главное действие

/// Следующий шаг по лекции: распознать → собрать конспект → подготовить материалы.
enum LecturePrimaryAction: Equatable {
    case recognize(pages: [String])
    case assemble(rebuild: Bool)
    case prepareStudy(rebuild: Bool)

    var title: String {
        switch self {
        case .recognize(let pages): "Распознать \(UIFormat.count(pages.count, "страницу", "страницы", "страниц"))"
        case .assemble(let rebuild): rebuild ? "Пересобрать конспект" : "Собрать конспект"
        case .prepareStudy(let rebuild): rebuild ? "Подготовить заново" : "Подготовить материалы"
        }
    }

    var systemImage: String {
        switch self {
        case .recognize: "text.viewfinder"
        case .assemble: "doc.text"
        case .prepareStudy: "graduationcap"
        }
    }

    /// Пока по лекции что-то идёт, следующий шаг не предлагается.
    @MainActor
    static func next(for lecture: LectureRecord, recognition: RecognitionCenter, assembly: AssemblyCenter,
                     study: StudyCenter) -> LecturePrimaryAction? {
        let id = lecture.id
        guard !recognition.isBusy(id), !assembly.isRunning(id), !study.isRunning(id) else { return nil }
        let pending = recognition.pendingPages(in: lecture)
        if !pending.isEmpty { return .recognize(pages: pending) }
        // Сводки из кэша: тексты читаются в фоне, пока их нет — следующий шаг не предлагается.
        guard let readiness = assembly.knownReadiness(lecture) else { return nil }
        if readiness.plan != nil, lecture.meta.konspekt == nil || readiness.isStale {
            return .assemble(rebuild: lecture.meta.konspekt != nil)
        }
        if lecture.meta.konspekt != nil, lecture.meta.study == nil || study.knownStale(lecture) {
            return .prepareStudy(rebuild: lecture.meta.study != nil)
        }
        return nil
    }
}

/// Какая кнопка тулбара лекции яркая: следующий шаг или «PDF» (SPEC, раздел 13). Яркая всегда одна.
enum LectureProminentButton: Equatable {
    case primary, pdf, none

    /// Распознать и собрать важнее экспорта: иначе в PDF уйдёт неполный или устаревший конспект.
    /// «Подготовить материалы» уступает «PDF» вне самопроверки. Пока фоновая сводка по текстам не готова,
    /// «PDF» не выделяется: через мгновение главной может стать «Пересобрать», и кнопки мигнули бы.
    static func choose(primary: LecturePrimaryAction?, pdfAvailable: Bool, summaryKnown: Bool,
                       tab: LectureTab) -> Self {
        switch primary {
        case .recognize, .assemble: .primary
        case .prepareStudy: pdfAvailable && !tab.isStudy ? .pdf : .primary
        case nil: pdfAvailable && summaryKnown ? .pdf : .none
        }
    }
}
