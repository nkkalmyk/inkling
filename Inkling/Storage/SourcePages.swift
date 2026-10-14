import CoreGraphics
import Foundation

/// Раздел источников лекции (SPEC, раздел 3).
enum SourceSection: String, Codable, CaseIterable, Identifiable, Sendable {
    /// «Мой конспект»: фото рукописи и PDF-сканы тетради.
    case notes
    /// «Слайды»: PDF преподавателя.
    case slides

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notes: "Мой конспект"
        case .slides: "Слайды"
        }
    }

    /// Папка раздела внутри папки лекции.
    var folderName: String { rawValue }
}

/// Откуда взята страница: отдельный файл-картинка или страница PDF. Пути — относительно `<раздел>/originals/`.
enum PageSource: Codable, Equatable, Hashable, Sendable {
    case image(file: String)
    case pdfPage(file: String, index: Int)

    var file: String {
        switch self {
        case .image(let file), .pdfPage(let file, _): file
        }
    }

    var isPDF: Bool {
        if case .pdfPage = self { true } else { false }
    }
}

/// Четырёхугольник документа в нормированных координатах изображения (0…1, начало внизу слева, как в Vision и Core Image).
struct Quad: Codable, Equatable, Hashable, Sendable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint

    /// Площадь как доля всего изображения (формула шнурков).
    var area: Double {
        let p = [topLeft, topRight, bottomRight, bottomLeft]
        var sum = 0.0
        for i in 0..<4 {
            let a = p[i], b = p[(i + 1) % 4]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }
}

/// Как обрезать фото рукописи (SPEC, раздел 3.2).
enum CropMode: Codable, Equatable, Hashable, Sendable {
    /// Автообрезка; `nil` — документ не найден, используется кадр целиком.
    case auto(Quad?)
    /// «Использовать оригинал»: без обрезки.
    case original
    /// Углы рамки, поправленные вручную.
    case manual(Quad)

    var quad: Quad? {
        switch self {
        case .auto(let quad): quad
        case .original: nil
        case .manual(let quad): quad
        }
    }
}

/// Страница раздела «Мой конспект».
struct NotePage: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var source: PageSource
    /// Дата съёмки из EXIF, если есть.
    var captureDate: Date?
    var crop: CropMode
    /// Поворот пользователем, четверти оборота по часовой стрелке (0…3).
    var rotation: Int = 0
    var addedAt: Date
}

/// Как получить текст слайда (SPEC, раздел 3.3).
enum SlideMode: String, Codable, CaseIterable, Sendable {
    /// Решает эвристика по текстовому слою.
    case auto
    case textLayer
    case image
}

/// Страница раздела «Слайды».
struct SlidePage: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var source: PageSource
    var mode: SlideMode = .auto
    /// Решение эвристики при импорте: текстовый слой непригоден, нужна картинка.
    var heuristicNeedsImage: Bool
    /// Короткая причина решения эвристики, для подсказки в интерфейсе.
    var heuristicReason: String?
    /// «Не включать в конспект» (титульники, «Спасибо за внимание»).
    var excluded: Bool = false
    var addedAt: Date

    /// Слайд отправляется в модель картинкой.
    var usesImage: Bool {
        switch mode {
        case .auto: heuristicNeedsImage || !source.isPDF
        case .textLayer: !source.isPDF
        case .image: true
        }
    }
}

/// Пути к файлам лекции (SPEC, раздел 6).
struct LecturePaths: Sendable {
    let folder: URL

    func sectionFolder(_ section: SourceSection) -> URL {
        folder.appendingPathComponent(section.folderName, isDirectory: true)
    }

    func originalsFolder(_ section: SourceSection) -> URL {
        sectionFolder(section).appendingPathComponent("originals", isDirectory: true)
    }

    func original(_ source: PageSource, in section: SourceSection) -> URL {
        originalsFolder(section).appendingPathComponent(source.file)
    }

    /// Обработанное фото рукописи: `notes/photos/<id>.jpg`.
    func notePhoto(_ id: String) -> URL {
        sectionFolder(.notes).appendingPathComponent("photos/\(id).jpg")
    }

    /// Картинка слайда для распознавания: `slides/images/<id>.jpg`.
    func slideImage(_ id: String) -> URL {
        sectionFolder(.slides).appendingPathComponent("images/\(id).jpg")
    }

    /// Текст страницы: `<раздел>/pages/<id>.md`.
    func pageText(_ id: String, in section: SourceSection) -> URL {
        sectionFolder(section).appendingPathComponent("pages/\(id).md")
    }
}

enum PageID {
    static func make() -> String { UUID().uuidString.lowercased() }
}
