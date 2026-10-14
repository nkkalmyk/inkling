import SwiftUI

@main
struct InklingApp: App {
    /// Юнит-тесты запускаются внутри приложения; настоящую папку хранения они трогать не должны.
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings: AppSettings
    @State private var library: Library

    init() {
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        _library = State(initialValue: Library(root: settings.storageRoot))
    }

    var body: some Scene {
        Window("Inkling", id: "main") {
            ContentView()
                .environment(library)
                .environment(settings)
                .environment(\.locale, Locale(identifier: "ru_RU"))
                .task {
                    appDelegate.library = library
                    if !Self.isRunningTests { library.open(root: settings.storageRoot) }
                }
                .onChange(of: settings.storageRootPath) { library.open(root: settings.storageRoot) }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Новая лекция…") { library.sheet = .newLecture(subject: library.selectedLecture?.meta.subject) }
                    .keyboardShortcut("n")
                Button("Новый предмет…") { library.sheet = .newSubject }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(settings)
                .environment(\.locale, Locale(identifier: "ru_RU"))
        }
    }
}
