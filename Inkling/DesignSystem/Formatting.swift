import Foundation

/// Даты и длительности в интерфейсе. Локаль задана здесь один раз: `Date.formatted` берёт локаль процесса,
/// а не `\.locale` из окружения SwiftUI.
enum UIFormat {
    static let locale = Locale(identifier: "ru_RU")

    /// Число со словом в нужной форме: «1 вопрос», «2 вопроса», «5 вопросов», «11 вопросов», «21 вопрос».
    nonisolated static func count(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let tens = abs(n) % 100, units = abs(n) % 10
        let word = (11...14).contains(tens) ? many : units == 1 ? one : (2...4).contains(units) ? few : many
        return "\(n) \(word)"
    }
}

extension Date {
    /// «14 окт., 15:30» — когда собран конспект, подготовлены материалы.
    var stamp: String {
        formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(UIFormat.locale))
    }

    /// «14 октября, 15:30:12» — версия в истории, где важны секунды.
    var preciseStamp: String {
        formatted(.dateTime.day().month().hour().minute().second().locale(UIFormat.locale))
    }
}

extension Duration {
    /// «3:07» — сколько идёт распознавание или сборка.
    var elapsed: String {
        formatted(.time(pattern: .minuteSecond))
    }
}
