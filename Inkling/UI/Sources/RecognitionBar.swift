import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: Распознавание

/// Ошибка, остановившая очередь распознавания (нет входа, лимит, нет движка), или страницы с ошибкой.
/// Прогресс показывает тулбар.
struct RecognitionBar: View {
    @Environment(RecognitionCenter.self) private var recognition
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let lecture: LectureRecord

    var body: some View {
        VStack(spacing: 0) {
            if let error = recognition.blockingError, recognition.batches[lecture.id] == nil {
                InlineNotice(.error, error.userMessage, systemImage: "exclamationmark.octagon.fill",
                             details: error.details, dismiss: { recognition.blockingError = nil }) {
                    if case .rateLimited = error {} else {
                        Button("Настройки…") { openSettings() }
                    }
                    if !pending.isEmpty {
                        Button("Повторить") { recognition.recognize(lectureID: lecture.id, pageIDs: pending) }
                    }
                }
                .transition(.notice(reduceMotion: reduceMotion))
                Divider()
            } else if !failed.isEmpty, !recognition.isBusy(lecture.id) {
                // Ошибки отдельных страниц: значок на миниатюре, здесь — общий счёт и повтор одним нажатием.
                InlineNotice(.error, "Не удалось распознать страниц: \(failed.count)",
                             systemImage: "exclamationmark.triangle.fill") {
                    Button("Повторить") { recognition.recognize(lectureID: lecture.id, pageIDs: failed) }
                }
                .transition(.notice(reduceMotion: reduceMotion))
                Divider()
            }
        }
        .motion(.standard, value: recognition.blockingError == nil)
        .motion(.standard, value: failed.isEmpty)
    }

    private var pending: [String] { recognition.pendingPages(in: lecture) }

    /// Страницы лекции, распознавание которых завершилось ошибкой.
    private var failed: [String] {
        (lecture.meta.notes.map(\.id) + lecture.meta.slides.map(\.id)).filter {
            if case .failed = recognition.state(of: $0) { true } else { false }
        }
    }
}

/// Значок состояния текста на миниатюре. Цвет только у ошибки; остальное — значок с подписью.
struct RecognitionBadge: View {
    @Environment(RecognitionCenter.self) private var recognition
    let pageID: String
    let lecture: LectureRecord

    var body: some View {
        Group {
            switch recognition.state(of: pageID) {
            case .queued:
                StatusSymbol(systemImage: "clock", label: "В очереди", onImage: true)
            case .running:
                ProgressView().controlSize(.mini).padding(Spacing.xs)
                    .background(.regularMaterial, in: Circle())
                    .accessibilityLabel("Распознаётся")
            case .failed(let error):
                StatusSymbol(systemImage: "exclamationmark.triangle.fill", label: error.userMessage,
                             tint: .statusError, onImage: true)
            case nil:
                if let note = lecture.meta.notes.first(where: { $0.id == pageID }) {
                    if note.text == nil {
                        StatusSymbol(systemImage: "text.badge.xmark", label: "Не распознано", onImage: true)
                    } else if note.textIsStale {
                        StatusSymbol(systemImage: "arrow.triangle.2.circlepath", label: "Фото изменено после распознавания",
                                     onImage: true)
                    } else if note.text?.manuallyEdited == true {
                        StatusSymbol(systemImage: "pencil", label: "Текст правлен вручную", onImage: true)
                    }
                } else if let slide = lecture.meta.slides.first(where: { $0.id == pageID }), slide.needsRecognition {
                    StatusSymbol(systemImage: "text.badge.xmark", label: "Не распознано", onImage: true)
                }
            }
        }
        .padding(Spacing.xs)
    }
}
