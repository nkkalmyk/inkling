import SwiftUI

/// Шкала отступов. Любой отступ и интервал в стеке берётся отсюда.
enum Spacing {
    /// 2 — строки внутри одной ячейки (тема и дата лекции).
    static let xxs: CGFloat = 2
    /// 4 — значок и подпись, плашки на миниатюре.
    static let xs: CGFloat = 4
    /// 8 — элементы в ряду, вертикальный отступ полос.
    static let s: CGFloat = 8
    /// 12 — внутренний отступ карточки, горизонтальный отступ полос.
    static let m: CGFloat = 12
    /// 16 — отступ содержимого экрана от краёв.
    static let l: CGFloat = 16
    /// 20 — отступ листа.
    static let xl: CGFloat = 20
    /// 24 — между разделами экрана.
    static let xxl: CGFloat = 24
    /// 32 — вокруг крупных состояний (итоги теста).
    static let xxxl: CGFloat = 32
}

/// Радиусы скругления. Все фигуры строятся с `.continuous`, как в системных контролах.
enum Radius {
    /// 4 — плашка («Оригинал», «Текст»).
    static let chip: CGFloat = 4
    /// 8 — миниатюра, вариант ответа, мелкая подложка.
    static let control: CGFloat = 8
    /// 12 — карточка, раздел, флеш-карточка.
    static let card: CGFloat = 12
}

extension RoundedRectangle {
    /// Скругление дизайн-системы: `RoundedRectangle.ds(Radius.card)`.
    static func ds(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

/// Ширины листов. Листы одного назначения одинаковой ширины.
enum SheetWidth {
    /// Короткий вопрос: имя предмета.
    static let compact: CGFloat = 400
    /// Обычная форма: лекция, экспорт.
    static let regular: CGFloat = 480
    /// Редактор с длинными полями: вопрос, карточка.
    static let wide: CGFloat = 620
}

/// Ширины колонок для чтения: длинный текст не растягивается на всё окно.
enum ReadingWidth {
    /// Вопрос теста, флеш-карточка.
    static let focused: CGFloat = 720
    /// Список или лента карточек.
    static let column: CGFloat = 820
}
