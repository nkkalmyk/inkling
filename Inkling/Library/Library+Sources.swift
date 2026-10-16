import AppKit
import Foundation

/// Импорт и правка источников лекции. Тяжёлая работа с файлами идёт в фоне через `SourceImporter`,
/// изменения `meta.json` — на главном потоке через `LibraryStore.mutateLecture`.
extension Library {
    struct ImportProgress: Equatable {
        var lectureID: UUID
        var done: Int
        var total: Int
    }

    /// PDF попал не в тот раздел, который ему подходит: нужно спросить (SPEC, раздел 3.1).
    struct PDFSectionQuestion: Identifiable {
        let id = UUID()
        var lectureID: UUID
        var requested: SourceSection
        var guess: SourceSection
        var pdfs: [URL]
        var others: [URL]
        var staging: URL?
    }

    // MARK: Импорт

    func importProviders(_ providers: [NSItemProvider], into section: SourceSection, lectureID: UUID) {
        guard !providers.isEmpty, let staging = try? ImportStaging.makeStagingFolder() else { return }
        Task {
            let urls = await ImportStaging.files(from: providers, staging: staging)
            if urls.isEmpty {
                errorMessage = "Не удалось получить файлы. Поддерживаются фото (JPG, PNG, HEIC) и PDF."
                try? FileManager.default.removeItem(at: staging)
                return
            }
            importFiles(urls, into: section, lectureID: lectureID, staging: staging)
        }
    }

    func importPasteboard(_ pasteboard: NSPasteboard, into section: SourceSection, lectureID: UUID) {
        guard let staging = try? ImportStaging.makeStagingFolder() else { return }
        let urls = ImportStaging.files(from: pasteboard, staging: staging)
        guard !urls.isEmpty else {
            try? FileManager.default.removeItem(at: staging)
            errorMessage = "В буфере обмена нет фото или PDF."
            return
        }
        importFiles(urls, into: section, lectureID: lectureID, staging: staging)
    }

    /// Импорт файлов. Если PDF явно относится к другому разделу, сначала задаётся вопрос.
    func importFiles(_ urls: [URL], into section: SourceSection, lectureID: UUID, staging: URL? = nil) {
        let pdfs = urls.filter { SourceImporter.kind(of: $0) == .pdf }
        let others = urls.filter { SourceImporter.kind(of: $0) != .pdf }
        guard !pdfs.isEmpty else {
            runImport([(section, urls)], lectureID: lectureID, staging: staging)
            return
        }
        // Открытие PDF для оценки текстового слоя может быть долгим: делаем это вне главного потока.
        Task {
            let guesses = await Task.detached(priority: .userInitiated) {
                pdfs.compactMap { try? PDFTools.guessSection($0) }
            }.value
            if let mismatch = guesses.first(where: { $0 != section }) {
                pdfQuestion = PDFSectionQuestion(lectureID: lectureID, requested: section, guess: mismatch,
                                                 pdfs: pdfs, others: others, staging: staging)
                return
            }
            runImport([(section, urls)], lectureID: lectureID, staging: staging)
        }
    }

    /// Ответ на вопрос о разделе PDF; `nil` — отмена.
    func answerPDFQuestion(_ question: PDFSectionQuestion, section: SourceSection?) {
        pdfQuestion = nil
        guard let section else {
            if !question.others.isEmpty {
                runImport([(question.requested, question.others)], lectureID: question.lectureID, staging: question.staging)
            } else if let staging = question.staging {
                try? FileManager.default.removeItem(at: staging)
            }
            return
        }
        runImport([(question.requested, question.others), (section, question.pdfs)],
                  lectureID: question.lectureID, staging: question.staging)
    }

    private func runImport(_ groups: [(SourceSection, [URL])], lectureID: UUID, staging: URL?) {
        let groups = groups.filter { !$0.1.isEmpty }
        guard !groups.isEmpty, let lecture = (try? store.findLecture(id: lectureID, hint: lecture(id: lectureID)?.folder)) ?? nil else {
            if let staging { try? FileManager.default.removeItem(at: staging) }
            return
        }
        let importer = SourceImporter(paths: LecturePaths(folder: lecture.folder))
        importProgress = ImportProgress(lectureID: lectureID, done: 0, total: 0)
        Task {
            var combined = ImportResult()
            for (section, urls) in groups {
                let result = await Task.detached(priority: .userInitiated) {
                    importer.importFiles(urls, into: section) { done, total in
                        Task { @MainActor in
                            self.importProgress = ImportProgress(lectureID: lectureID, done: done, total: total)
                        }
                    }
                }.value
                combined.notes += result.notes
                combined.slides += result.slides
                combined.skipped += result.skipped
            }
            if let staging { try? FileManager.default.removeItem(at: staging) }
            importProgress = nil
            mutate(lectureID) { $0.appendImported(combined) }
            // Новые страницы распознаются сразу после импорта (SPEC, раздел 13).
            let toRecognize = combined.notes.map(\.id) + combined.slides.filter(\.needsRecognition).map(\.id)
            if !toRecognize.isEmpty { recognition?.recognize(lectureID: lectureID, pageIDs: toRecognize) }
            if !combined.skipped.isEmpty {
                errorMessage = "Не всё удалось импортировать:\n"
                    + combined.skipped.map { "• \($0.name): \($0.reason)" }.joined(separator: "\n")
            }
        }
    }

    // MARK: Страницы

    func movePages(_ ids: [String], before target: String?, in section: SourceSection, lectureID: UUID) {
        mutate(lectureID) { $0.movePages(ids, before: target, in: section) }
    }

    /// Удаляет страницы: обработанные копии стираются (их можно пересоздать), оригиналы уходят в корзину.
    func deletePages(_ ids: Set<String>, in section: SourceSection, lectureID: UUID) {
        var removed: [PageSource: [String]] = [:]
        var remaining: [PageSource] = []
        guard let record = mutate(lectureID, { meta in
            removed = meta.removePages(ids, in: section)
            remaining = meta.sources(in: section)
        }) else { return }
        let importer = SourceImporter(paths: LecturePaths(folder: record.folder))
        let files = importer.filesToRemove(removed: removed, section: section, remainingSources: remaining)
        for url in files.derived { try? FileManager.default.removeItem(at: url) }
        for url in files.originals where FileManager.default.fileExists(atPath: url.path) {
            do { try store.trasher.trash(url) } catch { errorMessage = error.localizedDescription }
        }
    }

    func rotateNote(_ id: String, by quarterTurns: Int, lectureID: UUID) {
        var page: NotePage?
        guard let record = mutate(lectureID, { page = $0.rotateNote(id, by: quarterTurns) }), let page else { return }
        rerender(page, folder: record.folder, lectureID: lectureID)
    }

    /// «Использовать оригинал» (`.original`) или снова автообрезка (`.auto(nil)`).
    func setCrop(_ crop: CropMode, forNote id: String, lectureID: UUID) {
        var page: NotePage?
        guard let record = mutate(lectureID, { page = $0.setCrop(crop, forNote: id) }), let page else { return }
        rerender(page, folder: record.folder, lectureID: lectureID)
    }

    func setSlideMode(_ mode: SlideMode, for id: String, lectureID: UUID) {
        var page: SlidePage?
        guard let record = mutate(lectureID, { page = $0.setSlideMode(mode, for: id) }), let page else { return }
        let importer = SourceImporter(paths: LecturePaths(folder: record.folder))
        busyPages.insert(id)
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try importer.syncSlideFiles(page) }
            }.value
            if case .success(let text) = outcome, text != page.text {
                mutate(lectureID) { $0.setPageText(text, for: id) }
            }
            finishBusy(id, outcome.error)
            if outcome.error == nil, page.needsRecognition {
                recognition?.recognize(lectureID: lectureID, pageIDs: [id])
            }
        }
    }

    func setSlideExcluded(_ excluded: Bool, for id: String, lectureID: UUID) {
        mutate(lectureID) { $0.setSlideExcluded(excluded, for: id) }
    }

    func revertDateAdjustment(lectureID: UUID) {
        mutate(lectureID) { $0.revertDateAdjustment() }
    }

    func acceptDateAdjustment(lectureID: UUID) {
        mutate(lectureID) { $0.acceptDateAdjustment() }
    }

    /// Пересоздаёт обработанное фото в фоне; для автообрезки сохраняет найденный документ.
    private func rerender(_ page: NotePage, folder: URL, lectureID: UUID) {
        let importer = SourceImporter(paths: LecturePaths(folder: folder))
        busyPages.insert(page.id)
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try importer.renderNotePhoto(page) }
            }.value
            if case .success(let crop) = outcome {
                let hash = FileHash.sha256(LecturePaths(folder: folder).notePhoto(page.id))
                mutate(lectureID) { meta in
                    _ = meta.setCrop(crop, forNote: page.id)
                    if let i = meta.notes.firstIndex(where: { $0.id == page.id }) { meta.notes[i].imageHash = hash }
                }
            }
            finishBusy(page.id, outcome.error)
        }
    }

    private func finishBusy(_ id: String, _ error: Error?) {
        busyPages.remove(id)
        pageRevisions[id, default: 0] += 1
        if let error { errorMessage = error.localizedDescription }
        reload()
    }

    // MARK: Текст страниц

    /// Сохраняет правку текста. При первой правке результата модели прежняя версия уходит в историю (SPEC, раздел 4.1).
    func saveEditedText(_ text: String, pageID: String, lectureID: UUID) {
        guard let lecture = lecture(id: lectureID), let location = lecture.meta.page(pageID) else { return }
        let store = PageTextStore(paths: LecturePaths(folder: lecture.folder))
        guard store.read(pageID, in: location.section) != text else { return }
        let current = lecture.meta.pageText(pageID)
        do {
            try store.write(text, id: pageID, in: location.section, previous: current,
                            saveHistory: current?.manuallyEdited != true)
        } catch {
            errorMessage = "Не удалось сохранить текст: \(error.localizedDescription)"
            return
        }
        var info = current ?? PageText(origin: .manual, updatedAt: Date())
        info.manuallyEdited = true
        info.updatedAt = JSONCoding.rounded(Date())
        if current?.manuallyEdited != true || current?.origin == nil {
            mutate(lectureID) { $0.setPageText(info, for: pageID) }
        }
    }

    /// Восстанавливает версию из истории; текущая уходит в историю.
    func restoreVersion(_ entry: HistoryStore.Entry, pageID: String, lectureID: UUID) {
        guard let lecture = lecture(id: lectureID), let location = lecture.meta.page(pageID) else { return }
        let store = PageTextStore(paths: LecturePaths(folder: lecture.folder))
        do {
            let current = lecture.meta.pageText(pageID)
            let restored = try store.restore(entry, id: pageID, in: location.section, current: current)
            var info = restored ?? PageText(origin: .manual, updatedAt: Date(), manuallyEdited: true)
            info.updatedAt = JSONCoding.rounded(Date())
            mutate(lectureID) { $0.setPageText(info, for: pageID) }
            pageRevisions[pageID, default: 0] += 1
        } catch {
            errorMessage = "Не удалось восстановить версию: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func mutate(_ lectureID: UUID, _ change: (inout LectureMeta) throws -> Void) -> LectureRecord? {
        defer { reload() }
        do {
            return try store.mutateLecture(id: lectureID, change)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}

private extension Result {
    var error: Failure? {
        if case .failure(let error) = self { error } else { nil }
    }
}
