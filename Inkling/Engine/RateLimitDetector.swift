import Foundation

/// Распознавание исчерпанного лимита подписки по тексту ошибки (SPEC, раздел 2.2; docs/cli-notes.md).
/// Шаблоны держатся одним списком, чтобы их было легко дополнить реальными примерами.
enum RateLimitDetector {
    /// Регистронезависимые регулярные выражения.
    static let patterns: [String] = [
        #"usage limit reached"#,
        #"you['’]ve hit your\b[^\n.]*\blimit"#,
        #"you['’]ve reached your\b[^\n.]*\blimit"#,
        #"you['’]re out of extra usage"#,
        #"rate_limit_error"#,
        #"\brate[ -]limited\b"#,
        #"\b429\b"#,
        #"resource_exhausted"#,
        #"\bquota\b[^\n]*\b(exceeded|exhausted)\b"#,
        #"\blimit reached\b"#,
    ]

    private static let compiled: [NSRegularExpression] = patterns.map {
        try! NSRegularExpression(pattern: $0, options: [.caseInsensitive])
    }

    static func isRateLimited(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return compiled.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    /// Время сброса из текста вида `resets at 15:00`, `resets 3pm`, `resets 3:30pm (Europe/Moscow)`,
    /// `resets Oct 15, 3pm`, `resets at 2026-10-15T12:00:00Z`. Время без даты — ближайшее в будущем.
    static func resetDate(in text: String, now: Date = Date(), timeZone: TimeZone = .current) -> Date? {
        guard let match = firstMatch(#"resets?\s+(?:at\s+)?([^\n·|]+)"#, in: text)?.first else { return nil }
        var tail = match.trimmingCharacters(in: .whitespaces)

        if let iso = firstMatch(#"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?(?:Z|[+-]\d{2}:?\d{2}))"#, in: tail)?.first {
            return ISO8601DateFormatter().date(from: iso)
        }

        var zone = timeZone
        if let name = firstMatch(#"\(([A-Za-z_]+/[A-Za-z_/]+|UTC|GMT)\)"#, in: tail)?.first, let tz = TimeZone(identifier: name) {
            zone = tz
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone

        var day: DateComponents?
        if let parts = firstMatch(#"^([A-Za-z]{3,9})\.?\s+(\d{1,2}),?\s+"#, in: tail),
           let month = monthNumber(parts[0]), let d = Int(parts[1]) {
            day = DateComponents(month: month, day: d)
            if let range = tail.range(of: #"^[A-Za-z]{3,9}\.?\s+\d{1,2},?\s+"#, options: .regularExpression) {
                tail.removeSubrange(range)
            }
        }

        guard let time = firstMatch(#"^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b"#, in: tail, options: [.caseInsensitive]),
              var hour = Int(time[0]) else { return nil }
        let minute = Int(time[1]) ?? 0
        let meridiem = time[2].lowercased()
        if meridiem == "pm" && hour < 12 { hour += 12 }
        if meridiem == "am" && hour == 12 { hour = 0 }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }

        if let day {
            let year = calendar.component(.year, from: now)
            for y in [year, year + 1] {
                if let date = calendar.date(from: DateComponents(year: y, month: day.month, day: day.day,
                                                                 hour: hour, minute: minute)),
                   date > now.addingTimeInterval(-24 * 3600) { return date }
            }
            return nil
        }
        return calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute, second: 0),
                                 matchingPolicy: .nextTime)
    }

    private static func monthNumber(_ name: String) -> Int? {
        let names = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        return names.firstIndex(of: String(name.lowercased().prefix(3))).map { $0 + 1 }
    }

    /// Группы первого совпадения (пустая строка для несработавшей группы).
    private static func firstMatch(_ pattern: String, in text: String,
                                   options: NSRegularExpression.Options = [.caseInsensitive]) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<max(match.numberOfRanges, 2)).map { i in
            guard i < match.numberOfRanges, let range = Range(match.range(at: i), in: text) else { return "" }
            return String(text[range])
        }
    }
}
