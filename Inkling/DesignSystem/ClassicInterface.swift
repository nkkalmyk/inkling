import Foundation

/// Откат дизайн-правок аудита 2026-11 без пересборки: подпись идущего шага в тулбаре, напоминание о движке
/// при первом запуске, предложение подготовить материалы, перенос лекции перетаскиванием на предмет.
/// Включить прежний вид: `defaults write com.nkalmykov.inkling classicInterface -bool YES` и перезапустить
/// приложение; вернуть новый — `defaults delete com.nkalmykov.inkling classicInterface`.
enum ClassicInterface {
    static let key = "classicInterface"
}
