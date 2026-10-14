import CoreImage
import Foundation

/// Итог импорта файлов в раздел лекции. Файлы уже лежат в папке лекции; страницы нужно добавить в `meta.json`.
struct ImportResult: Sendable {
    var notes: [NotePage] = []
    var slides: [SlidePage] = []
    /// Пропущенные файлы с причиной, для сообщения пользователю.
    var skipped: [(name: String, reason: String)] = []
}

/// Импорт и пересоздание файлов страниц (SPEC, разделы 3.1–3.3). Работает только с файлами,
/// не трогает `meta.json` и не зависит от интерфейса; тяжёлое, вызывается не на главном потоке.
struct SourceImporter: Sendable {
    let paths: LecturePaths
    var now: @Sendable () -> Date = { Date() }

    enum Kind { case image, pdf, unsupported }

    static func kind(of url: URL) -> Kind {
        if url.pathExtension.lowercased() == "pdf" { return .pdf }
        return ImageProcessor.isSupportedImage(url) ? .image : .unsupported
    }

    /// Импортирует файлы в раздел. `progress(done, total)` вызывается после каждой страницы.
    func importFiles(_ urls: [URL], into section: SourceSection,
                     progress: @Sendable (Int, Int) -> Void = { _, _ in }) -> ImportResult {
        var result = ImportResult()
        let total = urls.reduce(0) { sum, url in
            sum + (Self.kind(of: url) == .pdf ? ((try? PDFTools.pageCount(url)) ?? 1) : 1)
        }
        var done = 0
        func step() {
            done += 1
            progress(done, total)
        }

        for url in urls {
            do {
                switch (Self.kind(of: url), section) {
                case (.image, .notes):
                    result.notes.append(try importNotePhoto(url))
                    step()
                case (.pdf, .notes):
                    result.notes += try importNotesPDF(url, step: step)
                case (.pdf, .slides):
                    result.slides += try importSlidesPDF(url, step: step)
                case (.image, .slides):
                    result.slides.append(try importSlideImage(url))
                    step()
                case (.unsupported, _):
                    result.skipped.append((url.lastPathComponent, "формат не поддерживается"))
                    step()
                }
            } catch {
                result.skipped.append((url.lastPathComponent, error.localizedDescription))
                step()
            }
        }
        // Фото рукописи по умолчанию идут по дате съёмки (SPEC, раздел 3.1); без даты — в конце, в исходном порядке.
        result.notes = Self.sortedByCaptureDate(result.notes)
        return result
    }

    static func sortedByCaptureDate(_ pages: [NotePage]) -> [NotePage] {
        pages.enumerated().sorted { a, b in
            switch (a.element.captureDate, b.element.captureDate) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    // MARK: Мой конспект

    private func importNotePhoto(_ url: URL) throws -> NotePage {
        let id = PageID.make()
        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension.lowercased()
        let source = PageSource.image(file: "\(id).\(ext)")
        let original = paths.original(source, in: .notes)
        // Дату берём у исходного файла: копия получает служебное имя и новую дату создания.
        let shot = ImageProcessor.shotDate(of: url)
        try copy(url, to: original)
        var page = NotePage(id: id, source: source, captureDate: shot,
                            crop: .auto(nil), addedAt: now())
        do {
            page.crop = try renderNotePhoto(page)
            page.imageHash = FileHash.sha256(paths.notePhoto(id))
        } catch {
            try? FileManager.default.removeItem(at: original)
            throw error
        }
        return page
    }

    private func importNotesPDF(_ url: URL, step: () -> Void) throws -> [NotePage] {
        let count = try PDFTools.pageCount(url)
        let source = "\(PageID.make()).pdf"
        let original = paths.originalsFolder(.notes).appendingPathComponent(source)
        try copy(url, to: original)
        var pages: [NotePage] = []
        for index in 0..<count {
            // Скан уже плоский: автообрезка по умолчанию выключена, её можно включить вручную.
            var page = NotePage(id: PageID.make(), source: .pdfPage(file: source, index: index), captureDate: nil,
                                crop: .original, addedAt: now())
            try renderNotePhoto(page)
            page.imageHash = FileHash.sha256(paths.notePhoto(page.id))
            pages.append(page)
            step()
        }
        return pages
    }

    /// Пересоздаёт `notes/photos/<id>.jpg` из оригинала. Возвращает режим обрезки с найденным документом.
    @discardableResult
    func renderNotePhoto(_ page: NotePage) throws -> CropMode {
        let image: CIImage
        switch page.source {
        case .image:
            image = try ImageProcessor.loadOriented(paths.original(page.source, in: .notes))
        case .pdfPage(_, let index):
            image = try PDFTools.renderPage(paths.original(page.source, in: .notes), index: index)
        }
        let result = try ImageProcessor.process(image, crop: page.crop, rotation: page.rotation)
        try write(result.jpeg, to: paths.notePhoto(page.id))
        if case .auto(nil) = page.crop { return .auto(result.detectedQuad) }
        return page.crop
    }

    // MARK: Слайды

    private func importSlidesPDF(_ url: URL, step: () -> Void) throws -> [SlidePage] {
        let texts = try PDFTools.pageTexts(url)
        let file = uniqueOriginalName(for: url, in: .slides)
        let original = paths.originalsFolder(.slides).appendingPathComponent(file)
        try copy(url, to: original)
        var pages: [SlidePage] = []
        for (index, text) in texts.enumerated() {
            let verdict = SlideTextHeuristic.analyze(text)
            var page = SlidePage(id: PageID.make(), source: .pdfPage(file: file, index: index),
                                 heuristicNeedsImage: verdict.needsImage, heuristicReason: verdict.reason,
                                 addedAt: now())
            page.text = try syncSlideFiles(page, textLayer: text)
            pages.append(page)
            step()
        }
        return pages
    }

    private func importSlideImage(_ url: URL) throws -> SlidePage {
        let id = PageID.make()
        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension.lowercased()
        let source = PageSource.image(file: "\(id).\(ext)")
        try copy(url, to: paths.original(source, in: .slides))
        var page = SlidePage(id: id, source: source, heuristicNeedsImage: true, heuristicReason: "картинка, а не PDF",
                             addedAt: now())
        page.text = try syncSlideFiles(page, textLayer: nil)
        return page
    }

    /// Приводит файлы слайда в соответствие с режимом: для картинки — `slides/images/<id>.jpg`
    /// (текст остаётся до распознавания), для текстового слоя — `slides/pages/<id>.md` с текстом из PDF
    /// (прежний текст уходит в историю). Возвращает новое описание текста страницы.
    @discardableResult
    func syncSlideFiles(_ page: SlidePage, textLayer: String? = nil) throws -> PageText? {
        if page.usesImage {
            let image: CIImage
            switch page.source {
            case .image:
                image = try ImageProcessor.loadOriented(paths.original(page.source, in: .slides))
            case .pdfPage(_, let index):
                image = try PDFTools.renderPage(paths.original(page.source, in: .slides), index: index)
            }
            let resized = ImageProcessor.resized(image, maxDimension: ImageProcessor.maxDimension)
            try write(try ImageProcessor.jpegData(resized), to: paths.slideImage(page.id))
            return page.text
        }
        try? FileManager.default.removeItem(at: paths.slideImage(page.id))
        guard case .pdfPage(_, let index) = page.source else { return page.text }
        let raw = try textLayer ?? PDFTools.pageTexts(paths.original(page.source, in: .slides))[index]
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        try PageTextStore(paths: paths).write(text, id: page.id, in: .slides, previous: page.text, now: now())
        return PageText(origin: .textLayer, updatedAt: JSONCoding.rounded(now()))
    }

    // MARK: Удаление

    /// Файлы, которые больше не нужны после удаления страниц: обработанные копии и оригиналы,
    /// на которые не ссылается ни одна оставшаяся страница.
    func filesToRemove(removed: [PageSource: [String]], section: SourceSection,
                       remainingSources: [PageSource]) -> (derived: [URL], originals: [URL]) {
        var derived: [URL] = []
        var originals: [URL] = []
        let stillUsed = Set(remainingSources.map(\.file))
        for (source, ids) in removed {
            for id in ids {
                switch section {
                case .notes: derived.append(paths.notePhoto(id))
                case .slides: derived.append(paths.slideImage(id))
                }
                derived.append(paths.pageText(id, in: section))
            }
            if !stillUsed.contains(source.file) {
                originals.append(paths.original(source, in: section))
            }
        }
        return (derived, Array(Set(originals)).sorted { $0.path < $1.path })
    }

    // MARK: Файлы

    private func uniqueOriginalName(for url: URL, in section: SourceSection) -> String {
        let base = FolderNaming.sanitize(url.deletingPathExtension().lastPathComponent)
        let folder = paths.originalsFolder(section)
        var index = 1
        while true {
            let name = index == 1 ? "\(base).pdf" : "\(base) (\(index)).pdf"
            if !FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) { return name }
            index += 1
        }
    }

    private func copy(_ source: URL, to target: URL) throws {
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.copyItem(at: source, to: target)
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicFile.write(data, to: url)
    }
}
