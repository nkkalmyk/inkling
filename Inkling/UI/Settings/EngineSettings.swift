import AppKit
import SwiftUI

struct EngineSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(EngineCenter.self) private var engines

    var body: some View {
        @Bindable var settings = settings
        Form {
            Picker("Основной движок", selection: $settings.primaryEngine) {
                Text(AppSettings.Engine.claude.title).tag(AppSettings.Engine.claude)
                Text(AppSettings.Engine.codex.title).tag(AppSettings.Engine.codex)
                Text(AppSettings.Engine.gemini.title).tag(AppSettings.Engine.gemini)
                Text(AppSettings.Engine.ollama.title).tag(AppSettings.Engine.ollama)
            }
            Picker("Запасной движок", selection: $settings.fallbackEngine) {
                ForEach(AppSettings.Engine.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Переключаться на запасной при лимите", isOn: $settings.autoFallback)
                .disabled(settings.fallbackEngine == .none || settings.fallbackEngine == settings.primaryEngine)
            Picker("Сейчас работает", selection: $settings.engineMode) {
                ForEach(AppSettings.EngineMode.allCases) { Text($0.title).tag($0) }
            }
            .help("То же, что меню «Модель» на панели лекции. Действует на новые запуски.")
            Section {
                Picker("Стиль по умолчанию", selection: $settings.assemblyStyle) {
                    ForEach(AssemblyStyle.allCases) { Text($0.title).tag($0) }
                }
                Picker("Модель Claude для сборки", selection: $settings.assemblyModel) {
                    Text("Как в настройках Claude Code").tag("")
                    ForEach(AppSettings.claudeModels, id: \.id) { Text($0.title).tag($0.id) }
                    if !settings.assemblyModel.isEmpty, !AppSettings.claudeModels.contains(where: { $0.id == settings.assemblyModel }) {
                        Text(settings.assemblyModel).tag(settings.assemblyModel)
                    }
                }
            } header: {
                Text("Сборка конспекта")
            } footer: {
                Text(settings.assemblyStyle.hint + " Opus даёт лучший результат, но быстрее расходует лимит подписки. "
                     + "Выбор модели действует только для Claude Code; Codex и локальная модель берут свои настройки.")
                    .foregroundStyle(.secondary)
            }
            Section("Claude Code") {
                TextField("Путь к claude", text: $settings.claudePathOverride, prompt: Text("Автопоиск"))
                ClaudeModelPicker()
                ConnectionCheckRow(engine: .claude)
            }
            Section {
                TextField("Путь к codex", text: $settings.codexPathOverride, prompt: Text("Автопоиск"))
                TextField("Модель", text: $settings.codexModel, prompt: Text("По умолчанию Codex"))
                ConnectionCheckRow(engine: .codex)
            } header: {
                Text("Codex (ChatGPT)")
            } footer: {
                Text("Работает по подписке ChatGPT через Codex CLI: установите его (brew install codex) и один раз выполните в Терминале "
                     + "«codex login». Если что-то не работает, откройте «Подробности» в проверке подключения.")
                    .foregroundStyle(.secondary)
            }
            Section {
                GeminiKeyField()
                GeminiModelPicker()
                ConnectionCheckRow(engine: .gemini)
            } header: {
                Text("Gemini (ключ AI Studio)")
            } footer: {
                Text("Вход по подписке Google AI Pro недоступен: Gemini CLI и Antigravity отказывают таким аккаунтам, а условия Google "
                     + "запрещают чужой вход из сторонних приложений. Нужен ключ с aistudio.google.com/apikey, он хранится в связке ключей. "
                     + "Страницы конспектов уходят в Google; на бесплатном уровне Google может использовать их для улучшения своих продуктов "
                     + "(проверьте условия).")
                    .foregroundStyle(.secondary)
            }
            Section {
                TextField("Путь к ollama", text: $settings.ollamaPathOverride, prompt: Text("Автопоиск"))
                OllamaModelPicker()
                ConnectionCheckRow(engine: .ollama)
            } header: {
                Text("Ollama (локально)")
            } footer: {
                Text("Приложение само запускает сервер Ollama, когда он нужен, и закрывает его при выходе. "
                     + "Подойдёт штатная qwen3.5:9b, модель inkling-ocr из docs/ollama или своя дообученная. "
                     + "Локальная модель медленнее облачных и чаще ошибается на плотном почерке: её результаты помечаются «проверьте». "
                     + "Если она зациклилась на странице, Inkling сам повторит распознавание.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Модель Claude: Sonnet, Opus, Haiku или своя строка (`--model`).
private struct ClaudeModelPicker: View {
    @Environment(AppSettings.self) private var settings
    private static let custom = "__custom__"

    var body: some View {
        @Bindable var settings = settings
        let known = AppSettings.claudeModels.map(\.id)
        Picker("Модель", selection: Binding(
            get: { known.contains(settings.claudeModel) ? settings.claudeModel : Self.custom },
            set: { settings.claudeModel = $0 == Self.custom ? "" : $0 })) {
            ForEach(AppSettings.claudeModels, id: \.id) { Text($0.title).tag($0.id) }
            Divider()
            Text("Другая…").tag(Self.custom)
        }
        if !known.contains(settings.claudeModel) {
            TextField("Своя модель", text: $settings.claudeModel, prompt: Text("например, claude-sonnet-5-5"))
        }
    }
}

/// Ключ Gemini: вводится один раз, дальше хранится в связке ключей и в поле не показывается.
private struct GeminiKeyField: View {
    @Environment(EngineCenter.self) private var engines
    @State private var input = ""
    @State private var failed = false

    var body: some View {
        LabeledContent("Ключ API") {
            VStack(alignment: .trailing, spacing: Spacing.s) {
                HStack {
                    SecureField("Ключ API", text: $input, prompt: Text(engines.geminiKeyStored ? "Ключ сохранён" : "Вставьте ключ"))
                        .labelsHidden()
                        .onSubmit(save)
                    Button("Сохранить", action: save)
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                    if engines.geminiKeyStored {
                        Button("Удалить") { failed = !engines.saveGeminiKey("") }
                    }
                }
                if failed {
                    Label("Связка ключей отказала в записи.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.statusError)
                        .font(.meta)
                }
            }
        }
        .onAppear { engines.refreshGeminiKey() }
    }

    private func save() {
        guard !input.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        failed = !engines.saveGeminiKey(input)
        if !failed { input = "" }
    }
}

/// Модель Gemini: из списка или своя строка.
private struct GeminiModelPicker: View {
    @Environment(AppSettings.self) private var settings
    private static let custom = "__custom__"

    var body: some View {
        @Bindable var settings = settings
        let known = AppSettings.geminiModels.map(\.id)
        Picker("Модель", selection: Binding(
            get: { known.contains(settings.geminiModel) ? settings.geminiModel : Self.custom },
            set: { settings.geminiModel = $0 == Self.custom ? "" : $0 })) {
            ForEach(AppSettings.geminiModels, id: \.id) { Text($0.title).tag($0.id) }
            Divider()
            Text("Другая…").tag(Self.custom)
        }
        if !known.contains(settings.geminiModel) {
            TextField("Своя модель", text: $settings.geminiModel, prompt: Text("например, gemini-3.5-flash"))
        }
    }
}

/// Модель Ollama из установленных; если сервер недоступен, имя можно вписать вручную.
private struct OllamaModelPicker: View {
    @Environment(AppSettings.self) private var settings
    @Environment(EngineCenter.self) private var engines

    var body: some View {
        @Bindable var settings = settings
        let models = engines.ollamaModels.map { $0.hasSuffix(":latest") ? String($0.dropLast(7)) : $0 }
        LabeledContent("Модель") {
            HStack {
                if models.isEmpty {
                    TextField("Модель", text: $settings.ollamaModel, prompt: Text(OllamaEngine.Config.defaultModel))
                        .labelsHidden()
                } else {
                    Picker("Модель", selection: $settings.ollamaModel) {
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                        if !models.contains(settings.ollamaModel) {
                            Text("\(settings.ollamaModel) (не установлена)").tag(settings.ollamaModel)
                        }
                    }
                    .labelsHidden()
                }
                Button {
                    engines.refreshOllamaModels()
                } label: {
                    if engines.loadingOllamaModels { ProgressView().controlSize(.small) } else { Text("Обновить список") }
                }
                .disabled(engines.loadingOllamaModels)
            }
        }
        if let error = engines.ollamaModelsError {
            Label(error.userMessage, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.statusError)
                .font(.meta)
        }
    }
}

private struct ConnectionCheckRow: View {
    @Environment(EngineCenter.self) private var engines
    let engine: EngineID
    @State private var showDetails = false

    var body: some View {
        LabeledContent("Подключение") {
            VStack(alignment: .leading, spacing: Spacing.s) {
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
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            if let path = report.binaryPath {
                Text("Путь: \(path) (\(report.binarySource ?? ""))").textSelection(.enabled)
            }
            if let version = report.version, !version.isEmpty {
                Text("Версия: \(version)")
            }
            if report.isOK, let model = report.model {
                Label("Работает: ответила модель \(model) за \(String(format: "%.1f", report.duration ?? 0)) с",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.statusSuccess)
            }
            if let error = report.error {
                Label(error.userMessage, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(Color.statusError)
                if !error.details.isEmpty {
                    DisclosureGroup("Подробности", isExpanded: $showDetails) {
                        Text(error.details)
                            .font(.mono)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .font(.meta)
    }
}
