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
                VStack(alignment: .leading, spacing: 6) {
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

private struct EngineSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(EngineCenter.self) private var engines

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
                ConnectionCheckRow(engine: .claude)
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

private struct ConnectionCheckRow: View {
    @Environment(EngineCenter.self) private var engines
    let engine: EngineID
    @State private var showDetails = false

    var body: some View {
        LabeledContent("Подключение") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button("Проверить подключение") { engines.checkConnection(engine) }
                        .disabled(engines.checking.contains(engine))
                    if engines.checking.contains(engine) {
                        ProgressView().controlSize(.small)
                        Text("Отправляю тестовый запрос…").foregroundStyle(.secondary)
                    }
                }
                if let report = engines.reports[engine] {
                    reportView(report)
                }
            }
        }
    }

    @ViewBuilder
    private func reportView(_ report: ConnectionReport) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let path = report.binaryPath {
                Text("Путь: \(path) (\(report.binarySource ?? ""))").textSelection(.enabled)
            }
            if let version = report.version, !version.isEmpty {
                Text("Версия: \(version)")
            }
            if report.isOK, let model = report.model {
                Label("Работает: ответила модель \(model) за \(String(format: "%.1f", report.duration ?? 0)) с",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if let error = report.error {
                Label(error.userMessage, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                if !error.details.isEmpty {
                    DisclosureGroup("Подробности", isExpanded: $showDetails) {
                        Text(error.details)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .font(.callout)
    }
}
