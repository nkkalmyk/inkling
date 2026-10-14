import SwiftUI

@main
struct InklingApp: App {
    /// Юнит-тесты запускаются внутри приложения; настоящую папку хранения они трогать не должны.
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings: AppSettings
    @State private var library: Library
    @State private var engines: EngineCenter
    @State private var recognition: RecognitionCenter
    @State private var assembly: AssemblyCenter

    init() {
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        let library = Library(root: settings.storageRoot)
        let engines = EngineCenter(settings: settings)
        let recognition = RecognitionCenter(library: library, router: { engines.router },
                                            timeout: { TimeInterval(settings.pageTimeoutSeconds) },
                                            maxParallel: { settings.maxParallelCalls })
        library.recognition = recognition
        _library = State(initialValue: library)
        _engines = State(initialValue: engines)
        _recognition = State(initialValue: recognition)
        _assembly = State(initialValue: AssemblyCenter(library: library, router: { engines.router },
                                                       threshold: { settings.chunkThresholdChars }))
    }

    var body: some Scene {
        Window("Inkling", id: "main") {
            ContentView()
                .environment(library)
                .environment(settings)
                .environment(engines)
                .environment(recognition)
                .environment(assembly)
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
                .environment(engines)
                .environment(library)
                .environment(\.locale, Locale(identifier: "ru_RU"))
        }
    }
}
