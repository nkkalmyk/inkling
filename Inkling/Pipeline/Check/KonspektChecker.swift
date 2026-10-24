import Foundation
import JavaScriptCore

/// Формула, которую KaTeX не смог разобрать.
struct BrokenFormula: Equatable, Sendable {
    var tex: String
    var display: Bool
    var message: String
}

/// Итог локальной проверки конспекта: без вызовов модели, тем же рендерером (KaTeX, `diagram.js`), что и в окне.
struct KonspektCheck: Equatable, Sendable {
    var brokenFormulas: [BrokenFormula] = []
    var diagramErrors = 0
    /// Чего не хватает учебному конспекту: оглавления, раздела примеров, источников.
    var missingStructure: [String] = []

    var isClean: Bool { brokenFormulas.isEmpty && diagramErrors == 0 && missingStructure.isEmpty }

    /// Короткое описание проблем для подсказки в интерфейсе.
    var summary: String {
        var parts: [String] = []
        if !brokenFormulas.isEmpty { parts.append("формул с ошибкой: \(brokenFormulas.count)") }
        if diagramErrors > 0 { parts.append("не отрисовано рисунков: \(diagramErrors)") }
        if !missingStructure.isEmpty { parts.append("нет: " + missingStructure.joined(separator: ", ")) }
        return parts.joined(separator: "; ")
    }
}

enum KonspektChecker {
    /// Проверка текста. Структура проверяется только у учебного конспекта (`study`), «Источники» — если выдержки были.
    static func check(_ markdown: String, study: Bool, expectSources: Bool) -> KonspektCheck {
        var result = KonspektCheck()
        if let report = renderReport(markdown) {
            result.brokenFormulas = report.broken
            result.diagramErrors = report.diagramErrors
        }
        if study { result.missingStructure = missingStructure(markdown, expectSources: expectSources) }
        return result
    }

    static func missingStructure(_ markdown: String, expectSources: Bool) -> [String] {
        let headings = markdown.components(separatedBy: "\n").filter { $0.hasPrefix("#") }
            .map { $0.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).lowercased() }
        var missing: [String] = []
        if !headings.contains(where: { $0.hasPrefix("оглавление") }) { missing.append("«Оглавление»") }
        if !headings.contains(where: { $0.contains("пример") || $0.contains("типовые вопросы") }) {
            missing.append("раздела примеров")
        }
        if expectSources, !headings.contains(where: { $0.hasSuffix("источники") || $0.contains(" источники") }) {
            missing.append("«Источники»")
        }
        return missing
    }

    // MARK: Рендер в JavaScriptCore

    private struct Report {
        var broken: [BrokenFormula]
        var diagramErrors: Int
    }

    private static func renderReport(_ markdown: String) -> Report? {
        guard let web = NotesWebView.webFolder else { return nil }
        let context = JSContext()!
        // В WebKit atob есть, в голом JavaScriptCore нет (нужен markdown-it).
        let atob: @convention(block) (String) -> String = { base64 in
            String(data: Data(base64Encoded: base64) ?? Data(), encoding: .isoLatin1) ?? ""
        }
        context.setObject(atob, forKeyedSubscript: "atob" as NSString)
        context.evaluateScript("var self = this; var globalThis = this;")
        for file in ["vendor/katex/katex.min.js", "vendor/katex/contrib/mhchem.min.js",
                     "vendor/markdown-it/markdown-it.umd.min.js", "diagram.js", "render.js"] {
            guard let source = try? String(contentsOf: web.appendingPathComponent(file), encoding: .utf8) else { return nil }
            context.evaluateScript(source)
        }
        guard let render = context.objectForKeyedSubscript("InklingRender"),
              let json = render.invokeMethod("check", withArguments: [markdown])?.toString(),
              let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return nil }
        let broken = (object["broken"] as? [[String: Any]] ?? []).compactMap { item -> BrokenFormula? in
            guard let tex = item["tex"] as? String else { return nil }
            return BrokenFormula(tex: tex, display: item["display"] as? Bool ?? false, message: item["message"] as? String ?? "")
        }
        return Report(broken: broken, diagramErrors: object["diagramErrors"] as? Int ?? 0)
    }
}
