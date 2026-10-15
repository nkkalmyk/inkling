import AppKit

/// Камера непрерывности (SPEC, раздел 3.1): пункт «Импорт с iPhone» в меню «Файл» и в контекстном меню раздела.
/// Система сама наполняет пункт («Сфотографировать», «Сканировать документы») и спрашивает цепочку ответчиков,
/// кто примет картинку или PDF; принимающий получает данные через буфер обмена в `readSelection(from:)`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, @preconcurrency NSServicesMenuRequestor {
    weak var library: Library?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Без регистрации AppKit не спрашивает приложение (validRequestor), примет ли оно данные из Служб,
        // и пункт «Импорт с iPhone» остаётся серым: Камера непрерывности считает, что принимать некому.
        NSApp.registerServicesMenuSendTypes([], returnTypes: ContinuityCamera.returnTypes)
    }

    /// Сервер Ollama, запущенный приложением, гасится вместе с ним (SPEC, раздел 13, этап 8).
    func applicationWillTerminate(_ notification: Notification) {
        OllamaServer.shared.stopIfOwned()
    }

    /// NSApplication передаёт этот запрос делегату, если первый ответчик и окно его не обработали.
    @objc func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                              returnType: NSPasteboard.PasteboardType?) -> Any? {
        return ContinuityCamera.accepts(sendType: sendType, returnType: returnType) && library?.importTarget != nil ? self : nil
    }

    func readSelection(from pasteboard: NSPasteboard) -> Bool {
        guard let library, let target = library.importTarget else { return false }
        library.importPasteboard(pasteboard, into: target.section, lectureID: target.lectureID)
        return true
    }
}
