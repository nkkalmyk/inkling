import SwiftUI

/// Выбранная страница крупно. Распознанный текст рядом появится вместе с распознаванием (этап 4),
/// пока для слайдов показывается текстовый слой PDF.
struct PageDetailView: View {
    @Environment(Library.self) private var library
    let lecture: LectureRecord
    let pageID: String?

    private var paths: LecturePaths { LecturePaths(folder: lecture.folder) }

    var body: some View {
        if let pageID, let location = lecture.meta.page(pageID) {
            switch location.section {
            case .notes:
                noteDetail(lecture.meta.notes[location.index], number: location.index + 1)
            case .slides:
                slideDetail(lecture.meta.slides[location.index], number: location.index + 1)
            }
        } else {
            ContentUnavailableView("Выберите страницу", systemImage: "doc.viewfinder",
                                   description: Text("Порядок меняется перетаскиванием, лишние страницы удаляются клавишей ⌫."))
        }
    }

    private func noteDetail(_ page: NotePage, number: Int) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Страница \(number)").font(.headline)
                if let date = page.captureDate {
                    Text(date.formatted(.dateTime.day().month().hour().minute().locale(Locale(identifier: "ru_RU"))))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ControlGroup {
                    Button { library.rotateNote(page.id, by: -1, lectureID: lecture.id) } label: {
                        Label("Повернуть влево", systemImage: "rotate.left")
                    }
                    Button { library.rotateNote(page.id, by: 1, lectureID: lecture.id) } label: {
                        Label("Повернуть вправо", systemImage: "rotate.right")
                    }
                }
                .fixedSize()
                if case .original = page.crop {
                    Button("Автообрезка") { library.setCrop(.auto(nil), forNote: page.id, lectureID: lecture.id) }
                } else {
                    Button("Использовать оригинал") { library.setCrop(.original, forNote: page.id, lectureID: lecture.id) }
                }
            }
            .disabled(library.busyPages.contains(page.id))
            .padding(10)
            Divider()
            PageImageView(source: paths.imageSource(for: page), maxPixel: 2000,
                          revision: library.pageRevisions[page.id] ?? 0)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if case .auto(nil) = page.crop, !library.busyPages.contains(page.id) {
                Text("Лист на фото не найден, используется кадр целиком.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
        }
    }

    private func slideDetail(_ page: SlidePage, number: Int) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Слайд \(number)").font(.headline)
                Spacer()
                if page.source.isPDF {
                    Picker("Распознавание", selection: Binding(
                        get: { page.mode },
                        set: { library.setSlideMode($0, for: page.id, lectureID: lecture.id) })) {
                        Text(page.heuristicNeedsImage ? "Авто: картинка" : "Авто: текст").tag(SlideMode.auto)
                        Text("Текстовый слой").tag(SlideMode.textLayer)
                        Text("Картинка").tag(SlideMode.image)
                    }
                    .fixedSize()
                    .help(page.heuristicReason.map { "Эвристика выбрала картинку: \($0)" } ?? "Текстовый слой выглядит нормально")
                }
                Toggle("Не включать в конспект", isOn: Binding(
                    get: { page.excluded },
                    set: { library.setSlideExcluded($0, for: page.id, lectureID: lecture.id) }))
            }
            .disabled(library.busyPages.contains(page.id))
            .padding(10)
            Divider()
            VSplitView {
                PageImageView(source: paths.imageSource(for: page), maxPixel: 2000,
                              revision: library.pageRevisions[page.id] ?? 0)
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
                if !page.usesImage {
                    SlideTextView(url: paths.pageText(page.id, in: .slides),
                                  revision: library.pageRevisions[page.id] ?? 0)
                        .frame(minHeight: 120)
                }
            }
        }
    }
}

private struct SlideTextView: View {
    let url: URL
    let revision: Int
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "Текстовый слой пуст." : text)
                .textSelection(.enabled)
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .task(id: "\(url.path)#\(revision)") {
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
    }
}
