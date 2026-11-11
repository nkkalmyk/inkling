import SwiftUI

/// Разделы лекции. Две зоны: «Материалы» (строгая) и «Самопроверка» (тёплая).
enum LectureTab: String, CaseIterable, Identifiable {
    case sources, notes, questions, quiz, flashcards

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sources: "Источники"
        case .notes: "Конспект"
        case .questions: "Вопросы"
        case .quiz: "Тест"
        case .flashcards: "Карточки"
        }
    }

    var isStudy: Bool { self == .questions || self == .quiz || self == .flashcards }

    /// ⌘1–⌘5 в меню «Вид».
    var shortcut: KeyEquivalent {
        KeyEquivalent(Character(String((Self.allCases.firstIndex(of: self) ?? 0) + 1)))
    }

    static let studyTabs: [LectureTab] = [.questions, .quiz, .flashcards]
}

/// Пункт переключателя в тулбаре: три сегмента, самопроверка — одним.
enum LectureZoneItem: String, CaseIterable, Identifiable {
    case sources, notes, study

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sources: "Источники"
        case .notes: "Конспект"
        case .study: "Самопроверка"
        }
    }

    init(_ tab: LectureTab) {
        self = switch tab {
        case .sources: .sources
        case .notes: .notes
        case .questions, .quiz, .flashcards: .study
        }
    }
}

// MARK: Запросы от тулбара и меню к экранам

/// Главная кнопка и меню просят экран запустить действие с его подтверждениями
/// («Конспект правился вручную…»). Экран забирает флаг (сбрасывает его) и выполняет запрос —
/// и когда флаг поднят при уже открытом экране, и когда экран только появился после переключения вкладки.
struct LectureRequests: Equatable {
    var assemble = false
    var prepareStudy = false
    var reviewCards = false
    /// «Файл → Добавить файлы…»: панель выбора открывает «Источники».
    var addFiles = false
}

extension EnvironmentValues {
    @Entry var lectureRequests: Binding<LectureRequests> = .constant(LectureRequests())
    /// Вкладка лекции видна. Открытые вкладки остаются в памяти скрытыми (переключение без пересоздания
    /// веб-вью), и скрытая не должна забирать фокус, клавиши, вставку и запросы тулбара.
    @Entry var isActiveTab = true
}
