import Foundation
import PDFKit

/// Переходы в готовом PDF: пункты оглавления становятся ссылками на свои разделы, заголовки — закладками
/// (боковая панель «Оглавление» в Просмотре). Печать WKWebView ссылок не сохраняет, а колонтитулы перерисовывают
/// страницы, поэтому места находятся по тексту уже в готовом файле. Не найденный пункт (например, заголовок
/// с формулой) просто остаётся без ссылки.
enum PDFNavigation {
    /// Заголовок конспекта в порядке документа.
    struct Heading: Decodable, Equatable {
        var id: String
        var level: Int
        var text: String
    }

    /// Пункт оглавления и якорь раздела, на который он ведёт.
    struct Link: Decodable, Equatable {
        var text: String
        var target: String
    }

    struct Outline: Decodable, Equatable {
        var headings: [Heading]
        var links: [Link]
    }

    /// JS для страницы конспекта: заголовки с якорями и ссылки оглавления. Текст формул KaTeX берётся без
    /// скрытой MathML-копии, иначе он не совпадёт с тем, что напечатано.
    static let outlineScript = """
    (function () {
      function text(el) {
        var copy = el.cloneNode(true);
        copy.querySelectorAll('.katex-mathml').forEach(function (n) { n.remove(); });
        return copy.textContent.replace(/\\s+/g, ' ').trim();
      }
      var headings = Array.prototype.map.call(document.querySelectorAll('#content h1[id], #content h2[id], #content h3[id]'),
        function (h) { return { id: h.id, level: +h.tagName.charAt(1), text: text(h) }; });
      var links = Array.prototype.map.call(document.querySelectorAll('nav.toc a[href^="#"]'),
        function (a) { return { text: text(a), target: a.getAttribute('href').slice(1) }; });
      return JSON.stringify({ headings: headings, links: links });
    })();
    """

    /// Что поставить при перерисовке страниц (`PDFFooter`): точки перехода у заголовков, ссылки на пунктах оглавления
    /// и закладки. Ставятся средствами CoreGraphics: PDFKit на PDF после печати пишет вместо страницы имя `##1`,
    /// и такие ссылки никуда не ведут, а закладки не записывает вовсе.
    struct Plan: Equatable {
        /// Именованная точка перехода (якорь заголовка) на странице с номером от нуля.
        struct Anchor: Equatable { var page: Int; var point: CGPoint; var name: String }
        /// Прямоугольник ссылки на странице и якорь, куда она ведёт.
        struct Link: Equatable { var page: Int; var rect: CGRect; var name: String }
        /// Закладка: название, страница (от нуля), верх строки и вложенные закладки.
        struct Bookmark: Equatable { var title: String; var page: Int; var top: CGFloat; var children: [Bookmark] }

        var anchors: [Anchor] = []
        var links: [Link] = []
        var bookmarks: [Bookmark] = []

        /// Закладки в формате `CGPDFContextSetOutline` (номера страниц там с единицы).
        func outlineDictionary() -> CFDictionary {
            func node(_ bookmark: Bookmark) -> [String: Any] {
                var item: [String: Any] = [kCGPDFOutlineTitle as String: bookmark.title,
                                           kCGPDFOutlineDestination as String: bookmark.page + 1,
                                           kCGPDFOutlineDestinationRect as String:
                                               CGRect(x: 0, y: bookmark.top, width: 0, height: 0).dictionaryRepresentation]
                if !bookmark.children.isEmpty { item[kCGPDFOutlineChildren as String] = bookmark.children.map(node) }
                return item
            }
            return [kCGPDFOutlineChildren as String: bookmarks.map(node)] as CFDictionary
        }
    }

    /// План переходов для напечатанного PDF; `nil`, если в нём нечего связывать.
    static func plan(_ outline: Outline, for url: URL) -> Plan? {
        guard let document = PDFDocument(url: url), !outline.headings.isEmpty else { return nil }
        let located = locate(outline, in: document)
        var plan = Plan()
        for (id, target) in located.headings { plan.anchors.append(.init(page: target.page, point: target.point, name: id)) }
        plan.anchors.sort { ($0.page, -$0.point.y) < ($1.page, -$1.point.y) }
        for link in outline.links {
            guard let entry = located.entries[link.target], located.headings[link.target] != nil else { continue }
            plan.links.append(.init(page: entry.page, rect: entry.bounds, name: link.target))
        }
        plan.bookmarks = bookmarks(outline.headings, targets: located.headings)
        return plan.anchors.isEmpty ? nil : plan
    }

    /// Где на страницах стоят пункты оглавления и заголовки. Оглавление ищется от его заголовка и дальше по порядку,
    /// заголовки — по порядку после последнего пункта оглавления: так одинаковые названия не путаются.
    static func locate(_ outline: Outline, in document: PDFDocument)
        -> (entries: [String: (page: Int, bounds: CGRect)], headings: [String: (page: Int, point: CGPoint)]) {
        var entries: [String: (page: Int, bounds: CGRect)] = [:]
        var headings: [String: (page: Int, point: CGPoint)] = [:]
        var cursor = Position(page: 0, top: .greatestFiniteMagnitude)
        if let tocTitle = outline.headings.first(where: { $0.text.compare("Оглавление", options: .caseInsensitive) == .orderedSame }),
           let found = find(tocTitle.text, after: cursor, in: document) {
            cursor = found.position
        }
        for link in outline.links {
            guard let found = find(link.text, after: cursor, in: document) else { continue }
            entries[link.target] = (found.position.page, found.bounds)
            cursor = found.position
        }
        let linked = Set(outline.links.map(\.target))
        for heading in outline.headings {
            // Заголовки до оглавления (титул, само «Оглавление») ищутся с начала документа.
            let start = linked.contains(heading.id) ? cursor : Position(page: 0, top: .greatestFiniteMagnitude)
            guard let found = find(heading.text, after: start, in: document) else { continue }
            // Чуть выше строки заголовка, чтобы при переходе он не прилипал к краю окна.
            let box = found.page.bounds(for: .mediaBox)
            headings[heading.id] = (found.position.page, CGPoint(x: box.minX, y: min(found.bounds.maxY + 12, box.maxY)))
            if linked.contains(heading.id) { cursor = found.position }
        }
        return (entries, headings)
    }

    /// Место в документе: номер страницы и верх строки (в PDF ось Y идёт снизу вверх, поэтому «дальше» — ниже).
    struct Position: Comparable {
        var page: Int
        var top: CGFloat

        static func < (lhs: Position, rhs: Position) -> Bool {
            lhs.page != rhs.page ? lhs.page < rhs.page : lhs.top > rhs.top
        }
    }

    /// Первое вхождение текста строго после `position`. Длинный текст ищется по началу: переносы строк в PDF
    /// разбивают его, а первых слов обычно хватает.
    private static func find(_ text: String, after position: Position, in document: PDFDocument)
        -> (page: PDFPage, bounds: CGRect, position: Position)? {
        let needle = prefix(of: text)
        guard !needle.isEmpty else { return nil }
        // Системный шрифт интерфейса (оглавление, таблицы) отдаёт в текстовом слое PDF букву «к» как «ĸ» (U+0138):
        // «сĸаляр». Поэтому текст ищется и в таком написании.
        let variants = [needle, needle.replacingOccurrences(of: "к", with: "ĸ")]
        var best: (page: PDFPage, bounds: CGRect, position: Position)?
        for variant in Set(variants) {
            for match in document.findString(variant, withOptions: [.caseInsensitive, .diacriticInsensitive]) {
                guard let page = match.pages.first else { continue }
                let bounds = match.bounds(for: page)
                let here = Position(page: document.index(for: page), top: bounds.maxY)
                guard position < here else { continue }
                if best.map({ here < $0.position }) ?? true { best = (page, bounds, here) }
                break
            }
        }
        return best
    }

    /// До 40 знаков, по границе слова.
    static func prefix(of text: String) -> String {
        let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard clean.count > 40 else { return clean }
        let cut = clean.prefix(40)
        return cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
    }

    /// Закладки по уровням заголовков: h2 внутри h1, h3 внутри h2. Одинокий h1 («Конспект») не оборачивает
    /// остальное: его разделы встают на верхний уровень.
    static func bookmarks(_ headings: [Heading], targets: [String: (page: Int, point: CGPoint)]) -> [Plan.Bookmark] {
        let found = headings.filter { targets[$0.id] != nil }
        let topLevel = found.filter { $0.level == 1 }.count <= 1 ? 2 : 1
        func build(_ items: ArraySlice<Heading>) -> [Plan.Bookmark] {
            var result: [Plan.Bookmark] = []
            var index = items.startIndex
            while index < items.endIndex {
                let heading = items[index]
                var end = items.index(after: index)
                while end < items.endIndex, items[end].level > heading.level { end = items.index(after: end) }
                if let target = targets[heading.id] {
                    result.append(.init(title: heading.text, page: target.page, top: target.point.y,
                                        children: build(items[items.index(after: index)..<end])))
                }
                index = end
            }
            return result
        }
        return build(ArraySlice(found.filter { $0.level >= topLevel }))
    }
}
