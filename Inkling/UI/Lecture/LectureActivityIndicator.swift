import SwiftUI

// MARK: Активность

/// Что сейчас идёт по лекции: импорт, распознавание, сборка, подготовка материалов, исправление формул, экспорт.
struct LectureActivityIndicator: View {
    @Environment(Library.self) private var library
    @Environment(RecognitionCenter.self) private var recognition
    @Environment(AssemblyCenter.self) private var assembly
    @Environment(StudyCenter.self) private var study
    @Environment(KonspektCheckCenter.self) private var checker
    let lecture: LectureRecord
    var exportingPDFSince: Date?
    var exportingHTMLSince: Date?

    var body: some View {
        ActivityIndicator(activities: activities)
    }

    private var activities: [Activity] {
        let id = lecture.id
        var result: [Activity] = []
        if let progress = library.importProgress, progress.lectureID == id {
            result.append(Activity(id: "import", title: "Импорт",
                                   detail: progress.total > 0 ? "\(progress.done) из \(progress.total)" : "Подготовка",
                                   fraction: progress.total > 0 ? Double(progress.done) / Double(progress.total) : nil,
                                   cancel: { library.cancelImport(lectureID: id) }))
        }
        if let batch = recognition.batches[id] {
            let processed = batch.done + batch.failed
            var detail = ["\(processed) из \(batch.total)"]
            if batch.failed > 0 { detail.append("ошибок: \(batch.failed)") }
            if let engine = batch.engine { detail.append(engine.title) }
            result.append(Activity(id: "recognition", title: "Распознавание", detail: detail.joined(separator: " · "),
                                   fraction: Double(processed) / Double(max(batch.total, 1)),
                                   startedAt: batch.startedAt, note: batch.note,
                                   cancel: { recognition.cancel(lectureID: id) }))
        }
        if let run = assembly.runs[id] {
            var detail: [String] = []
            if run.totalCalls > 1, !run.merging { detail.append("частей \(run.finishedCalls) из \(run.totalCalls - 1)") }
            if let engine = run.engine { detail.append(engine.title) }
            result.append(Activity(id: "assembly", title: run.merging ? "Склейка частей" : "Сборка конспекта",
                                   detail: detail.isEmpty ? nil : detail.joined(separator: " · "),
                                   fraction: run.totalCalls > 1 ? Double(run.finishedCalls) / Double(run.totalCalls) : nil,
                                   startedAt: run.startedAt, note: run.note, cancel: { assembly.cancel(id) }))
        }
        if let run = study.runs[id] {
            result.append(Activity(id: "study", title: "Подготовка материалов", detail: run.engine?.title,
                                   startedAt: run.startedAt, note: run.note, cancel: { study.cancel(id) }))
        }
        if checker.isFixing(id) {
            result.append(Activity(id: "fix", title: "Исправление формул", cancel: { checker.cancelFix(id) }))
        }
        if let exportingPDFSince {
            result.append(Activity(id: "pdf", title: "Экспорт в PDF", startedAt: exportingPDFSince))
        }
        if let exportingHTMLSince {
            result.append(Activity(id: "html", title: "Экспорт в HTML", startedAt: exportingHTMLSince))
        }
        return result
    }
}
