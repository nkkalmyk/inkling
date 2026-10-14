import SwiftUI

/// Экран лекции. На этапе 1 вкладки — заготовки, содержимое появляется на этапах 2–6.
struct LectureView: View {
    enum Tab: String, CaseIterable, Identifiable {
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
    }

    @Environment(Library.self) private var library
    let lecture: LectureRecord
    @State private var tab: Tab = .sources

    var body: some View {
        VStack(spacing: 0) {
            if lecture.hasConflict {
                ConflictBanner { library.revealInFinder(lecture.folder) }
            }
            if let adjustment = lecture.meta.dateAdjustment {
                DateAdjustedBanner(newDate: lecture.meta.date, previousDate: adjustment.previousDate,
                                   revert: { library.revertDateAdjustment(lectureID: lecture.id) },
                                   dismiss: { library.acceptDateAdjustment(lectureID: lecture.id) })
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(lecture.meta.topic)
        .navigationSubtitle("\(lecture.meta.subject) · \(lecture.meta.date.formatted)")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Раздел", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ToolbarItem {
                ExportMenu(lecture: lecture)
            }
            ToolbarItem {
                Button {
                    library.sheet = .editLecture(lecture.id)
                } label: {
                    Label("Изменить", systemImage: "pencil")
                }
                .help("Изменить тему, дату или предмет")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .sources:
            SourcesView(lecture: lecture, showNotes: { tab = .notes })
        case .notes:
            NotesView(lecture: lecture)
        case .questions:
            QuestionsView(lecture: lecture, showNotes: { tab = .notes })
        case .quiz:
            QuizView(lecture: lecture, showNotes: { tab = .notes })
        case .flashcards:
            FlashcardsView(lecture: lecture, showNotes: { tab = .notes })
        }
    }
}

private struct DateAdjustedBanner: View {
    let newDate: CalendarDate
    let previousDate: CalendarDate
    let revert: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock").foregroundStyle(.blue)
            Text("Дата изменена по фото: \(newDate.formatted) (было \(previousDate.formatted)).")
                .font(.callout)
            Spacer()
            Button("Вернуть", action: revert)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Оставить новую дату")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.blue.opacity(0.1))
    }
}

private struct ConflictBanner: View {
    let reveal: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text("У этой лекции есть конфликтные копии iCloud. Приложение не перезаписывает их само: проверьте файлы в Finder.")
                .font(.callout)
            Spacer()
            Button("Показать в Finder", action: reveal)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.yellow.opacity(0.15))
    }
}
