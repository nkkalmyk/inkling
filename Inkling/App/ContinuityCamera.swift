import AppKit
import SwiftUI

/// Камера непрерывности (SPEC, раздел 3.1): пункт «Импорт с iPhone» в меню «Файл» и в контекстном меню раздела.
/// Система сама наполняет пункт («Сфотографировать», «Сканировать документы») и спрашивает цепочку ответчиков,
/// кто примет картинку или PDF; принимающий получает данные через буфер обмена в `readSelection(from:)`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, @preconcurrency NSServicesMenuRequestor {
    weak var library: Library?
    private var menuObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI может пересобрать главное меню: проверяем пункт при обновлениях приложения (проверка дешёвая).
        menuObserver = NotificationCenter.default.addObserver(forName: NSApplication.didUpdateNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ensureImportMenuItem() }
        }
    }

    /// Сервер Ollama, запущенный приложением, гасится вместе с ним (SPEC, раздел 13, этап 8).
    func applicationWillTerminate(_ notification: Notification) {
        OllamaServer.shared.stopIfOwned()
    }

    private func ensureImportMenuItem() {
        guard let fileMenu = NSApp.mainMenu?.items.compactMap(\.submenu)
            .first(where: { menu in menu.items.contains { $0.title == "Новая лекция…" } }),
              !fileMenu.items.contains(where: { $0.identifier == NSMenuItem.importFromDeviceIdentifier })
        else { return }
        let anchor = fileMenu.items.lastIndex { $0.title == "Новый предмет…" } ?? (fileMenu.items.count - 1)
        fileMenu.insertItem(.separator(), at: anchor + 1)
        fileMenu.insertItem(ContinuityCamera.menuItem(), at: anchor + 2)
    }

    /// NSApplication передаёт этот запрос делегату, если первый ответчик и окно его не обработали.
    @objc func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                              returnType: NSPasteboard.PasteboardType?) -> Any? {
        ContinuityCamera.accepts(sendType: sendType, returnType: returnType) && library?.importTarget != nil ? self : nil
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

    /// Принимаем только входящие картинки и PDF (сканы документов), ничего не отправляем.
    static func accepts(sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Bool {
        guard sendType == nil, let returnType else { return false }
        return returnType == .pdf || NSImage.imageTypes.contains(returnType.rawValue)
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
            let menu = NSMenu()
            menu.addItem(withTitle: "Добавить файлы…", action: #selector(addFiles), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(ContinuityCamera.menuItem())
            return menu
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

/// Кнопка «Добавить» с меню по обычному щелчку: «Добавить файлы…» и «Импорт с iPhone»
/// (системный пункт сам наполняется командами «Сфотографировать», «Сканировать документы»).
/// Нужна, потому что правый щелчок на тачпаде может быть выключен. Сделана на AppKit:
/// системный пункт Камеры непрерывности работает только в NSMenu, а снимок получает
/// первый ответчик — эта кнопка.
struct ContinuityCameraButton: NSViewRepresentable {
    /// `nil` — только значок «+»; иначе обычная кнопка с подписью.
    var title: String?
    var help = "Добавить файлы или снять с iPhone"
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
            // Снимок с iPhone система отдаёт первому ответчику: становимся им до показа меню.
            window?.makeFirstResponder(self)
            let menu = NSMenu()
            menu.addItem(withTitle: "Добавить файлы…", action: #selector(addFiles), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(ContinuityCamera.menuItem())
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
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
