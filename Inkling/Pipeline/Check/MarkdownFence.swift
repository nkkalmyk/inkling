import Foundation

/// Блоки кода Markdown построчно, по правилам CommonMark — тем же, что у markdown-it в рендере: блок открывают
/// три и больше «`» или «~», закрывает строка только из того же символа, не короче открывающей. Раньше пять мест
/// разбирали это по-разному: `~~~` понимало только одно, проверка структуры считала заголовком `#` внутри кода
/// (аудит 2026-11, B19).
struct MarkdownFence {
    private var open: (character: Character, count: Int)?

    /// Строка внутри блока кода (после `consume` открывающей границы и до закрывающей).
    var isInside: Bool { open != nil }

    /// Учитывает строку. `true` — это граница блока (открывающая или закрывающая).
    mutating func consume<S: StringProtocol>(_ line: S) -> Bool {
        if let current = open {
            guard Self.closes(line, character: current.character, count: current.count) else { return false }
            open = nil
            return true
        }
        guard let marker = Self.marker(line) else { return false }
        open = marker
        return true
    }

    /// Открывающая граница: символ и длина; `nil`, если строка не начинает блок кода.
    static func marker<S: StringProtocol>(_ line: S) -> (character: Character, count: Int)? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let count = trimmed.prefix { $0 == first }.count
        return count >= 3 ? (first, count) : nil
    }

    static func closes<S: StringProtocol>(_ line: S, character: Character, count: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= count && trimmed.allSatisfy { $0 == character }
    }
}
