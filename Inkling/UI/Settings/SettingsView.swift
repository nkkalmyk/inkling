import AppKit
import SwiftUI

/// Настройки (SPEC, раздел 9). На этапе 1 работает выбор папки хранения, остальное — заготовка.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("Основные", systemImage: "gearshape") }
            EngineSettings()
                .tabItem { Label("Движок", systemImage: "cpu") }
            LiteratureSettings()
                .tabItem { Label("Учебники", systemImage: "books.vertical") }
            ProcessingSettings()
                .tabItem { Label("Обработка", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 560)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @Environment(AppSettings.self) private var settings
    @State private var confirmReset = false
    @State private var promptMessage: String?

    private func resetPrompts() {
        do {
            let backup = try PromptLibrary(root: settings.storageRoot).resetToDefaults()
            promptMessage = backup.map { "Готово. Ваши версии сохранены в \($0.path)." } ?? "Промпты и так были по умолчанию."
        } catch {
            promptMessage = "Не удалось сбросить промпты: \(error.localizedDescription)"
        }
    }

    var body: some View {
        Form {
            LabeledContent("Папка хранения") {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text(settings.storageRoot.path)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    HStack {
                        Button("Выбрать…", action: chooseFolder)
                        Button("Показать в Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([settings.storageRoot])
                        }
                        if settings.storageRoot != AppSettings.defaultStorageRoot {
                            Button("По умолчанию") { settings.storageRootPath = AppSettings.defaultStorageRoot.path }
                        }
                    }
                }
            }
            LabeledContent("Промпты") {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    HStack {
                        Button("Открыть папку промптов") {
                            let prompts = PromptLibrary(root: settings.storageRoot)
                            try? prompts.installMissingDefaults()
                            NSWorkspace.shared.open(prompts.folder)
                        }
                        Button("Сбросить к умолчанию…") { confirmReset = true }
                    }
                    if let promptMessage {
                        Text(promptMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .confirmationDialog("Вернуть промпты по умолчанию?", isPresented: $confirmReset) {
                Button("Сбросить") { resetPrompts() }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Изменённые файлы не удалятся: они будут перенесены в папку «_старые».")
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Выбрать"
        panel.message = "Папка, в которой Inkling хранит предметы и лекции"
        panel.directoryURL = settings.storageRoot.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            settings.storageRootPath = url.path
        }
    }
}
