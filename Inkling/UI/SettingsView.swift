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
            ProcessingSettings()
                .tabItem { Label("Обработка", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 560)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Form {
            LabeledContent("Папка хранения") {
                VStack(alignment: .leading, spacing: 6) {
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
                Text("Папка промптов и сброс к умолчанию появятся вместе с распознаванием.")
                    .foregroundStyle(.secondary)
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

private struct EngineSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Picker("Основной движок", selection: $settings.primaryEngine) {
                Text(AppSettings.Engine.claude.title).tag(AppSettings.Engine.claude)
            }
            Picker("Запасной движок", selection: $settings.fallbackEngine) {
                Text(AppSettings.Engine.none.title).tag(AppSettings.Engine.none)
            }
            .help("Других движков пока нет: Gemini CLI и Antigravity CLI недоступны для этого аккаунта")
            Toggle("Переключаться на запасной при лимите", isOn: $settings.autoFallback)
                .disabled(settings.fallbackEngine == .none)
            Section("Claude Code") {
                TextField("Путь к claude", text: $settings.claudePathOverride, prompt: Text("Автопоиск"))
                TextField("Модель", text: $settings.claudeModel, prompt: Text("sonnet"))
                LabeledContent("Подключение") {
                    Button("Проверить подключение") {}
                        .disabled(true)
                        .help("Появится вместе с движком")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProcessingSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Stepper(value: $settings.pageTimeoutSeconds, in: 30...600, step: 30) {
                LabeledContent("Таймаут на страницу", value: "\(settings.pageTimeoutSeconds) с")
            }
            Picker("Параллельных вызовов", selection: $settings.maxParallelCalls) {
                Text("1").tag(1)
                Text("2").tag(2)
            }
            .pickerStyle(.segmented)
            Stepper(value: $settings.chunkThresholdChars, in: 10_000...200_000, step: 5_000) {
                LabeledContent("Сборка по частям, если текста больше",
                               value: "\(settings.chunkThresholdChars.formatted(.number.locale(Locale(identifier: "ru_RU")))) симв.")
            }
            Toggle("Готовить учебные материалы сразу после сборки", isOn: $settings.autoStudyMaterials)
            Toggle("Сохранять временные папки при ошибке (для отладки)", isOn: $settings.keepTempFoldersOnError)
        }
        .formStyle(.grouped)
    }
}
