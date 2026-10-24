import Foundation

/// Нормализация слов для поиска по учебникам: нижний регистр, `ё → е`, грубый стемминг усечением до 6 букв.
/// Один и тот же разбор для текста страниц и для запроса, поэтому «теплоты», «теплота» и «теплотой» совпадают.
enum RussianNormalizer {
    static let stemLength = 6
    static let minimumLength = 3

    /// Слова без смысла для поиска: союзы, местоимения, служебные слова учебного текста.
    static let stopwords: Set<String> = [
        "это", "как", "так", "для", "или", "что", "при", "его", "они", "она", "оно", "все", "всех", "где", "когда",
        "если", "быть", "был", "была", "были", "будет", "есть", "может", "могут", "также", "только", "между", "через",
        "после", "перед", "более", "менее", "очень", "один", "одна", "одно", "два", "три", "который", "которая",
        "которые", "которых", "этот", "эта", "эти", "этих", "того", "такой", "такие", "свой", "своей", "нужно",
        "можно", "тогда", "потому", "чтобы", "либо", "рис", "табл", "стр", "пример", "задача", "лекция",
    ]

    /// Основы служебных слов в той же форме, что и слова индекса.
    private static let stopStems: Set<String> = Set(stopwords.map { String($0.prefix(stemLength)) })

    /// Слова текста в нормальной форме (с повторами, в порядке появления).
    static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        func flush() {
            if current.count >= minimumLength { result.append(String(current.prefix(stemLength))) }
            current = ""
        }
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                current.unicodeScalars.append(scalar == "ё" ? "е" : scalar)
            } else {
                flush()
            }
        }
        flush()
        return result
    }

    /// Слова запроса: без служебных слов и повторов, в порядке появления.
    static func queryTokens(_ text: String) -> [String] {
        var seen = Set<String>()
        return tokens(text).filter { token in
            !stopStems.contains(token) && seen.insert(token).inserted
        }
    }

    /// Строка для индекса: нормальные формы слов через пробел.
    static func indexText(_ text: String) -> String { tokens(text).joined(separator: " ") }
}
