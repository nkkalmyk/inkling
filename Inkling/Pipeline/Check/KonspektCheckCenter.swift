import Foundation
import Observation

/// Локальная проверка конспекта (формулы, рисунки, структура) и исправление сломанных формул одним коротким вызовом модели
/// по кнопке. Сама проверка модель не вызывает.
@MainActor
@Observable
final class KonspektCheckCenter {
    private(set) var checks: [UUID: KonspektCheck] = [:]
    private(set) var fixing: Set<UUID> = []
    var errors: [UUID: AIError] = [:]
    /// Сколько формул исправлено в последнем запуске (для подсказки).
    private(set) var lastFixed: [UUID: Int] = [:]

    @ObservationIgnored private let library: Library
    @ObservationIgnored private let router: @MainActor () -> EngineRouter
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var keys: [UUID: String] = [:]

    init(library: Library, router: @escaping @MainActor () -> EngineRouter) {
        self.library = library
        self.router = router
    }

    static let fixSchema = """
    {"type":"object","additionalProperties":false,"required":["fixes"],"properties":{"fixes":{"type":"array","items":\
    {"type":"object","additionalProperties":false,"required":["id","tex"],"properties":\
    {"id":{"type":"integer","minimum":1},"tex":{"type":"string"}}}}}}
    """

    func isFixing(_ lectureID: UUID) -> Bool { fixing.contains(lectureID) }

    /// Пересчитывает проверку в фоне, если конспект изменился. Читает файл вне главного потока (iCloud).
    func refresh(_ lecture: LectureRecord) {
        guard lecture.meta.konspekt != nil else { checks[lecture.id] = nil; return }
        let revision = library.konspektRevision[lecture.id] ?? 0
        let key = "\(revision)|\(lecture.meta.konspekt?.updatedAt.timeIntervalSince1970 ?? 0)"
        guard keys[lecture.id] != key else { return }
        keys[lecture.id] = key
        let id = lecture.id, folder = lecture.folder, info = lecture.meta.konspekt
        Task {
            let result = await Self.run(folder: folder, study: info?.style == .study, expectSources: info?.literature != nil)
            if keys[id] == key { checks[id] = result }
        }
    }

    @concurrent
    private static func run(folder: URL, study: Bool, expectSources: Bool) async -> KonspektCheck? {
        guard let text = KonspektStore(folder: folder).read() else { return nil }
        return KonspektChecker.check(text, study: study, expectSources: expectSources)
    }

    // MARK: Исправление формул

    func fixFormulas(_ lectureID: UUID) {
        guard !fixing.contains(lectureID), let lecture = library.lecture(id: lectureID),
              let check = checks[lectureID], !check.brokenFormulas.isEmpty else { return }
        errors[lectureID] = nil
        fixing.insert(lectureID)
        let router = router(), prompts = library.prompts, broken = check.brokenFormulas
        tasks[lectureID] = Task {
            defer {
                fixing.remove(lectureID)
                tasks[lectureID] = nil
            }
            do {
                let fixed = try await requestFixes(broken, router: router, prompts: prompts)
                let applied = try await apply(fixed, to: lecture)
                lastFixed[lectureID] = applied
                keys[lectureID] = nil
                if let current = library.lecture(id: lectureID) { refresh(current) }
            } catch let error as AIError {
                if error != .cancelled { errors[lectureID] = error }
            } catch {
                errors[lectureID] = .invalidOutput(error.localizedDescription)
            }
        }
    }

    func cancelFix(_ lectureID: UUID) { tasks[lectureID]?.cancel() }

    private func requestFixes(_ broken: [BrokenFormula], router: EngineRouter, prompts: PromptLibrary) async throws -> [Int: String] {
        let list = broken.enumerated().map { "[\($0.offset + 1)] \($0.element.display ? "строчная вынесенная" : "в строке")\n"
            + "Формула: \($0.element.tex)\nОшибка: \($0.element.message)" }.joined(separator: "\n\n")
        let prompt = PromptLibrary.render(try prompts.template("fix-formulas.md"), values: ["формулы": list])
        let response = try await router.run(AIRequest(prompt: prompt, systemPrompt: "Ты исправляешь синтаксис LaTeX. Инструменты не нужны.",
                                                      format: .json(schema: Self.fixSchema), timeout: 180))
        guard let json = response.json ?? JSONExtractor.object(in: response.text),
              let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let items = object["fixes"] as? [[String: Any]] else {
            throw AIError.invalidOutput("Не удалось разобрать ответ с исправленными формулами.")
        }
        var result: [Int: String] = [:]
        for item in items {
            if let id = item["id"] as? Int, let tex = item["tex"] as? String, (1...broken.count).contains(id) { result[id] = tex }
        }
        return result
    }

    /// Подставляет исправления в конспект. Принимаются только те, что теперь разбираются; прежний текст уходит в историю.
    private func apply(_ fixes: [Int: String], to lecture: LectureRecord) async throws -> Int {
        guard let check = checks[lecture.id] else { return 0 }
        let store = KonspektStore(folder: lecture.folder)
        guard var text = store.read() else { return 0 }
        var applied = 0
        for (index, formula) in check.brokenFormulas.enumerated() {
            guard let fixedTex = fixes[index + 1], fixedTex != formula.tex else { continue }
            let delimiter = formula.display ? "$$" : "$"
            guard KonspektChecker.check(delimiter + fixedTex + delimiter, study: false, expectSources: false).brokenFormulas.isEmpty,
                  let range = text.range(of: delimiter + formula.tex + delimiter) else { continue }
            text.replaceSubrange(range, with: delimiter + fixedTex + delimiter)
            applied += 1
        }
        guard applied > 0 else { return 0 }
        try store.write(text, previous: lecture.meta.konspekt)
        let now = JSONCoding.rounded(Date())
        library.mutate(lecture.id) { $0.konspekt?.updatedAt = now }
        library.konspektRevision[lecture.id, default: 0] += 1
        return applied
    }
}
