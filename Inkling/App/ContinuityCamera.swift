import AppKit
import OSLog
import SwiftUI

/// Временная диагностика Камеры непрерывности (DEBUGCC).
let ccLog = Logger(subsystem: "com.nkalmykov.inkling", category: "continuity")

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
        ccLog.notice("delegate validRequestor send=\(sendType?.rawValue ?? "nil", privacy: .public) return=\(returnType?.rawValue ?? "nil", privacy: .public) target=\(self.library?.importTarget != nil, privacy: .public)") // DEBUGCC
        return ContinuityCamera.accepts(sendType: sendType, returnType: returnType) && library?.importTarget != nil ? self : nil
    }

    func readSelection(from pasteboard: NSPasteboard) -> Bool {
        guard let library, let target = library.importTarget else { return false }
        library.importPasteboard(pasteboard, into: target.section, lectureID: target.lectureID)
        return true
    }
}

enum ContinuityCamera {
    static func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Импорт с iPhone", action: nil, keyEquivalent: "")
        item.identifier = NSMenuItem.importFromDeviceIdentifier
        return item
    }

    /// Что приложение принимает от Камеры непрерывности: снимки и PDF (сканы документов).
    static let returnTypes: [NSPasteboard.PasteboardType] =
        [.pdf] + NSImage.imageTypes.map { NSPasteboard.PasteboardType($0) }

    /// Принимаем только входящие картинки и PDF, ничего не отправляем.
    static func accepts(sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Bool {
        guard sendType == nil, let returnType else { return false }
        return returnTypes.contains(returnType)
    }
}

/// Фон раздела источников: по правому щелчку становится первым ответчиком и показывает меню
/// «Добавить файлы…» и «Импорт с iPhone», а снимки с iPhone передаёт в `onImport`.
struct ContinuityCameraAnchor: NSViewRepresentable {
    var onAddFiles: () -> Void
    var onImport: (NSPasteboard) -> Void

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.onAddFiles = onAddFiles
        view.onImport = onImport
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.onAddFiles = onAddFiles
        view.onImport = onImport
    }

    final class AnchorView: NSView, @preconcurrency NSServicesMenuRequestor {
        var onAddFiles: () -> Void = {}
        var onImport: (NSPasteboard) -> Void = { _ in }

        override var acceptsFirstResponder: Bool { true }

        override func menu(for event: NSEvent) -> NSMenu? {
            window?.makeFirstResponder(self)
            // Пункт «Импорт с iPhone» в контекстное меню вставляет сам AppKit (если ответчик примет снимок);
            // добавленный вручную он не наполняет, и тот остаётся серым.
            let menu = NSMenu()
            menu.addItem(withTitle: "Добавить файлы…", action: #selector(addFiles), keyEquivalent: "").target = self
            return menu
        }

        @objc private func addFiles() { onAddFiles() }

        override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                     returnType: NSPasteboard.PasteboardType?) -> Any? {
            ccLog.notice("button validRequestor send=\(sendType?.rawValue ?? "nil", privacy: .public) return=\(returnType?.rawValue ?? "nil", privacy: .public)") // DEBUGCC
            if ContinuityCamera.accepts(sendType: sendType, returnType: returnType) { return self }
            return super.validRequestor(forSendType: sendType, returnType: returnType)
        }

        func readSelection(from pasteboard: NSPasteboard) -> Bool {
            onImport(pasteboard)
            return true
        }
    }
}

/// Кнопка «Добавить» с меню по обычному щелчку: «Добавить файлы…» и «Импорт с iPhone»
/// (системный пункт сам наполняется командами «Сфотографировать», «Сканировать документы»).
/// Нужна, потому что правый щелчок на тачпаде может быть выключен. Сделана на AppKit:
/// системный пункт Камеры непрерывности работает только в NSMenu, а снимок получает
/// первый ответчик — эта кнопка.
struct ContinuityCameraButton: NSViewRepresentable {
    /// `nil` — только значок «+»; иначе обычная кнопка с подписью.
    var title: String?
    var help = "Добавить файлы или снять с iPhone"
    /// Перед показом меню: делает раздел кнопки целевым, снимок с iPhone ляжет в него.
    var onOpen: () -> Void = {}
    var onAddFiles: () -> Void
    var onImport: (NSPasteboard) -> Void

    func makeNSView(context: Context) -> ButtonView {
        let button = ButtonView()
        configure(button)
        return button
    }

    func updateNSView(_ button: ButtonView, context: Context) {
        configure(button)
    }

    private func configure(_ button: ButtonView) {
        button.onOpen = onOpen
        button.onAddFiles = onAddFiles
        button.onImport = onImport
        button.toolTip = help
        button.setAccessibilityLabel(title ?? "Добавить")
        if let title {
            button.title = title
            button.image = nil
            button.bezelStyle = .push
            button.isBordered = true
        } else {
            button.title = ""
            button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Добавить")
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
        }
    }

    final class ButtonView: NSButton, @preconcurrency NSServicesMenuRequestor {
        var onOpen: () -> Void = {}
        var onAddFiles: () -> Void = {}
        var onImport: (NSPasteboard) -> Void = { _ in }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            target = self
            action = #selector(showMenu)
            setContentHuggingPriority(.required, for: .horizontal)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

        override var acceptsFirstResponder: Bool { true }

        @objc private func showMenu() {
            onOpen()
            // Снимок с iPhone система отдаёт первому ответчику: становимся им до показа меню.
            window?.makeFirstResponder(self)
            let menu = NSMenu()
            menu.addItem(withTitle: "Добавить файлы…", action: #selector(addFiles), keyEquivalent: "").target = self
            ccLog.notice("button showMenu fr=\(String(describing: self.window?.firstResponder.map { type(of: $0) }), privacy: .public) event=\(String(describing: NSApp.currentEvent?.type), privacy: .public)") // DEBUGCC
            if let event = NSApp.currentEvent, [.leftMouseUp, .leftMouseDown].contains(event.type) {
                // Как контекстное меню: пункт Камеры непрерывности AppKit вставит сам и наполнит iPhone.
                NSMenu.popUpContextMenu(menu, with: event, for: self)
            } else {
                // С клавиатуры: обычное меню под кнопкой с системным пунктом.
                menu.addItem(.separator())
                menu.addItem(ContinuityCamera.menuItem())
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
            }
            ccLog.notice("button menu closed items=\(menu.items.map { "\($0.title):\($0.isEnabled)" }.joined(separator: ","), privacy: .public)") // DEBUGCC
        }

        @objc private func addFiles() { onAddFiles() }

        override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                     returnType: NSPasteboard.PasteboardType?) -> Any? {
            if ContinuityCamera.accepts(sendType: sendType, returnType: returnType) { return self }
            return super.validRequestor(forSendType: sendType, returnType: returnType)
        }

        func readSelection(from pasteboard: NSPasteboard) -> Bool {
            onImport(pasteboard)
            return true
        }
    }
}
