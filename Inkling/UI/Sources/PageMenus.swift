import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: Меню

struct NotePageMenu: View {
    @Environment(Library.self) private var library
    @Environment(RecognitionCenter.self) private var recognition
    let page: NotePage
    let lecture: LectureRecord

    var body: some View {
        // Ручную правку меню не перезаписывает: для этого — кнопка на странице, она спрашивает подтверждение.
        let edited = page.text?.manuallyEdited == true
        let busy = recognition.state(of: page.id) != nil && !isFailed
        Button("Распознать заново") { recognition.recognize(lectureID: lecture.id, pageIDs: [page.id]) }
            .disabled(edited || busy)
        Button("Распознать подробно") { recognition.recognize(lectureID: lecture.id, pageIDs: [page.id], detailed: true) }
            .disabled(edited || busy)
        Divider()
        Button("Повернуть влево") { library.rotateNote(page.id, by: -1, lectureID: lecture.id) }
        Button("Повернуть вправо") { library.rotateNote(page.id, by: 1, lectureID: lecture.id) }
        Divider()
        if case .original = page.crop {
            Button("Автообрезка") { library.setCrop(.auto(nil), forNote: page.id, lectureID: lecture.id) }
        } else {
            Button("Использовать оригинал") { library.setCrop(.original, forNote: page.id, lectureID: lecture.id) }
        }
        Divider()
        Button("Показать оригинал в Finder") {
            library.revealInFinder(LecturePaths(folder: lecture.folder).original(page.source, in: .notes))
        }
        Button("Удалить страницу", role: .destructive) {
            library.requestDeletePages([page.id], lectureID: lecture.id)
        }
    }

    private var isFailed: Bool {
        if case .failed = recognition.state(of: page.id) { true } else { false }
    }
}

struct SlidePageMenu: View {
    @Environment(Library.self) private var library
    let page: SlidePage
    let lecture: LectureRecord

    var body: some View {
        if page.source.isPDF {
            Picker("Распознавание", selection: Binding(
                get: { page.mode },
                set: { library.setSlideMode($0, for: page.id, lectureID: lecture.id) })) {
                Text(autoTitle).tag(SlideMode.auto)
                Text("Текстовый слой").tag(SlideMode.textLayer)
                Text("Распознать как картинку").tag(SlideMode.image)
            }
        }
        // Не Toggle: любой Toggle в окне выключает в SwiftUI «Импорт с iPhone» (Камеру непрерывности).
        Button {
            library.setSlideExcluded(!page.excluded, for: page.id, lectureID: lecture.id)
        } label: {
            if page.excluded {
                Label("Не включать в конспект", systemImage: "checkmark")
            } else {
                Text("Не включать в конспект")
            }
        }
        Divider()
        Button("Удалить слайд", role: .destructive) {
            library.requestDeletePages([page.id], lectureID: lecture.id)
        }
    }

    private var autoTitle: String {
        page.heuristicNeedsImage ? "Автоматически (картинка)" : "Автоматически (текстовый слой)"
    }
}
