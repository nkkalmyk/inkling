import Foundation

/// Содержимое `meta.json` лекции. Связи держатся на `id`, а не на пути к папке (SPEC, раздел 6).
/// Поля следующих этапов (порядок источников, хеши, флаги правок, движки) добавляются
/// как необязательные, чтобы старые файлы продолжали читаться.
struct LectureMeta: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var id: UUID
    var subject: String
    var topic: String
    var date: CalendarDate
    var createdAt: Date
    var updatedAt: Date
    /// Раздел «Мой конспект», в порядке страниц.
    var notes: [NotePage] = []
    /// Раздел «Слайды», в порядке страниц.
    var slides: [SlidePage] = []
    /// Дата уже один раз подстраивалась под дату съёмки фото (SPEC, раздел 13).
    var dateAutoAdjusted: Bool = false
    /// Показать плашку «Дата изменена по фото · Вернуть»; хранит прежнюю дату.
    var dateAdjustment: DateAdjustment?
    /// Собранный конспект `konspekt.md` (SPEC, раздел 4).
    var konspekt: ArtifactInfo?
    /// Учебные материалы `study.json`; `inputHash` — хеш конспекта.
    var study: ArtifactInfo?

    init(id: UUID = UUID(), subject: String, topic: String, date: CalendarDate, now: Date = Date()) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.subject = subject
        self.topic = topic
        self.date = date
        self.createdAt = JSONCoding.rounded(now)
        self.updatedAt = createdAt
    }

    /// Отмечает изменение.
    mutating func touch(_ now: Date = Date()) {
        updatedAt = JSONCoding.rounded(now)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, subject, topic, date, createdAt, updatedAt, notes, slides
        case dateAutoAdjusted, dateAdjustment, konspekt, study
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try c.decode(UUID.self, forKey: .id)
        subject = try c.decodeIfPresent(String.self, forKey: .subject) ?? ""
        topic = try c.decodeIfPresent(String.self, forKey: .topic) ?? ""
        date = try c.decode(CalendarDate.self, forKey: .date)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        // id и имя файла страницы подставляются в пути: из чужого или повреждённого meta.json
        // страницы с `..` и `/` отбрасываются, иначе приложение тронуло бы файлы вне папки лекции.
        notes = (try c.decodeIfPresent([NotePage].self, forKey: .notes) ?? [])
            .filter { PageID.isSafe($0.id) && $0.source.hasSafeFileName }
        slides = (try c.decodeIfPresent([SlidePage].self, forKey: .slides) ?? [])
            .filter { PageID.isSafe($0.id) && $0.source.hasSafeFileName }
        dateAutoAdjusted = try c.decodeIfPresent(Bool.self, forKey: .dateAutoAdjusted) ?? false
        dateAdjustment = try c.decodeIfPresent(DateAdjustment.self, forKey: .dateAdjustment)
        konspekt = try c.decodeIfPresent(ArtifactInfo.self, forKey: .konspekt)
        study = try c.decodeIfPresent(ArtifactInfo.self, forKey: .study)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(id, forKey: .id)
        try c.encode(subject, forKey: .subject)
        try c.encode(topic, forKey: .topic)
        try c.encode(date, forKey: .date)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(notes, forKey: .notes)
        try c.encode(slides, forKey: .slides)
        try c.encode(dateAutoAdjusted, forKey: .dateAutoAdjusted)
        try c.encodeIfPresent(dateAdjustment, forKey: .dateAdjustment)
        try c.encodeIfPresent(konspekt, forKey: .konspekt)
        try c.encodeIfPresent(study, forKey: .study)
    }

    func page(_ id: String) -> (section: SourceSection, index: Int)? {
        if let i = notes.firstIndex(where: { $0.id == id }) { return (.notes, i) }
        if let i = slides.firstIndex(where: { $0.id == id }) { return (.slides, i) }
        return nil
    }
}

/// Результат модели уровня лекции: конспект, позже учебные материалы (SPEC, раздел 4.1).
struct ArtifactInfo: Codable, Equatable, Sendable {
    var engine: EngineID?
    var model: String?
    var createdAt: Date
    var updatedAt: Date
    var manuallyEdited = false
    /// Хеш входных данных: для конспекта — тексты страниц и их порядок, для учебных материалов — хеш конспекта.
    var inputHash: String
    var mode: AssemblyMode?
    /// Из скольких частей собирался (больше одной — сборка по частям со склейкой).
    var parts = 1
    /// Сколько нераспознанных страниц пропущено при сборке.
    var skippedPages = 0
    /// Есть, если конспект дополнен кнопкой «Дополнить». Пересборка создаёт описание заново, и дополнение сбрасывается.
    var enrichment: EnrichmentInfo?
    /// Как собран конспект; `nil` у собранных до появления «Учебного конспекта» (это была точная сборка).
    var style: AssemblyStyle?
    /// Книги и страницы учебников, выдержки из которых получила модель при учебной сборке.
    var literature: [String]?
}

/// Как был дополнен конспект (`Enrichment`): сколько блоков осталось и сколько убрал проверяющий проход.
struct EnrichmentInfo: Codable, Equatable, Sendable {
    var createdAt: Date
    var engine: EngineID?
    var model: String?
    var added = 0
    var removedByCheck = 0
    /// Проверяющий проход отработал; если нет, блоки не проверены.
    var verified = true
}

struct DateAdjustment: Codable, Equatable, Sendable {
    var previousDate: CalendarDate
}

/// JSON файлов данных: даты в ISO 8601 с точностью до секунды, чтение принимает и доли секунды.
enum JSONCoding {
    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let withoutFraction = Date.ISO8601FormatStyle()

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(withoutFraction))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = try? withFraction.parse(raw) { return date }
            if let date = try? withoutFraction.parse(raw) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Ожидалась дата ISO 8601, получено «\(raw)»")
        }
        return decoder
    }

    /// Отбрасывает доли секунды, чтобы дата не менялась после записи и чтения.
    static func rounded(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}
