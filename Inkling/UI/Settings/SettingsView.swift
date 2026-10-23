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

private struct EngineSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(EngineCenter.self) private var engines

    var body: some View {
        @Bindable var settings = settings
        Form {
            Picker("Основной движок", selection: $settings.primaryEngine) {
                Text(AppSettings.Engine.claude.pickerTitle).tag(AppSettings.Engine.claude)
                Text(AppSettings.Engine.codex.pickerTitle).tag(AppSettings.Engine.codex)
                Text(AppSettings.Engine.ollama.pickerTitle).tag(AppSettings.Engine.ollama)
            }
            Picker("Запасной движок", selection: $settings.fallbackEngine) {
                ForEach(AppSettings.Engine.allCases) { Text($0.pickerTitle).tag($0) }
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
                HStack(spacing: Spacing.s) {
                    Text("Codex (ChatGPT)")
                    Label("Не проверен вживую", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Работает по подписке ChatGPT через Codex CLI: установите его (brew install codex) и один раз выполните в Терминале "
                     + "«codex login». Движок написан по документации OpenAI и пробным запускам без входа, но ни разу не проверялся "
                     + "с живой подпиской: если что-то не работает, откройте «Подробности» в проверке подключения и сообщите об ошибке.")
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
                     + "Модель inkling-ocr создаётся по инструкции в docs/ollama. Локальная модель медленнее Claude "
                     + "и чаще ошибается на плотном почерке: её результаты помечаются «проверьте».")
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


/// Учебники для учебной сборки: коллекции книг (PDF), привязка предметов, индекс с распознаванием сканов.
private struct LiteratureSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Library.self) private var library
    @Environment(LiteratureCenter.self) private var literature
    @State private var newCollection = ""

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Использовать учебники при сборке", isOn: $settings.literatureEnabled)
            } footer: {
                Text("Для «Учебного конспекта» приложение находит в ваших учебниках страницы по теме лекции и передаёт их модели "
                     + "для объяснений и точных формулировок. Сканы распознаются на этом компьютере (Vision), индекс лежит в "
                     + "Application Support, в облако уходят только найденные выдержки.")
                    .foregroundStyle(.secondary)
            }
            ForEach(settings.literatureCollections.keys.sorted(), id: \.self) { collection in
                Section(collection) {
                    ForEach(settings.literatureCollections[collection] ?? [], id: \.self) { path in
                        bookRow(path: path, collection: collection)
                    }
                    Button("Добавить книги…") { addBooks(to: collection) }
                }
            }
            Section("Новая коллекция") {
                HStack {
                    TextField("Название", text: $newCollection, prompt: Text("Например, Физика"))
                    Button("Создать") {
                        let name = newCollection.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty, settings.literatureCollections[name] == nil else { return }
                        settings.literatureCollections[name] = []
                        newCollection = ""
                    }
                    .disabled(newCollection.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if !settings.literatureCollections.isEmpty {
                Section("Предметы") {
                    ForEach(library.subjectNames, id: \.self) { subject in
                        Picker(subject, selection: Binding(
                            get: { settings.literatureSubjectCollections[subject] ?? "" },
                            set: { settings.literatureSubjectCollections[subject] = $0.isEmpty ? nil : $0 })) {
                            Text("Без учебников").tag("")
                            ForEach(settings.literatureCollections.keys.sorted(), id: \.self) { Text($0).tag($0) }
                        }
                    }
                }
            }
            Section("Индекс") {
                HStack {
                    Button(literature.isIndexing ? "Остановить" : "Обновить индекс") {
                        literature.isIndexing ? literature.cancel() : literature.startIndexing()
                    }
                    Button("Очистить индекс", role: .destructive) { literature.clearIndex() }
                        .disabled(literature.isIndexing)
                }
                if let progress = literature.progress {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        ProgressView(value: Double(progress.pagesDone), total: Double(max(progress.pagesTotal, 1)))
                        Text("Книга \(progress.bookNumber) из \(progress.bookCount): \(progress.title), \(progress.pagesDone) из \(progress.pagesTotal) стр.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let summary = literature.lastSummary, !summary.skippedBooks.isEmpty {
                    Text("Пропущено: " + summary.skippedBooks.joined(separator: "; ")).font(.caption).foregroundStyle(.secondary)
                }
                if let error = literature.errorMessage {
                    Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(Color.statusError).font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { literature.refresh() }
    }

    private func bookRow(path: String, collection: String) -> some View {
        let info = literature.info(forPath: path)
        return HStack {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(LiteratureIndexer.title(of: URL(fileURLWithPath: path))).lineLimit(1).truncationMode(.middle)
                Text(status(info)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                settings.literatureCollections[collection]?.removeAll { $0 == path }
                literature.removeFromIndex(path: path)
            } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Убрать книгу из коллекции и индекса")
        }
    }

    private func status(_ info: LiteratureBookInfo?) -> String {
        guard let info else { return "Ещё не в индексе" }
        if info.isComplete {
            return info.ocrPages > 0 ? "Скан: распознано \(info.ocrPages) из \(info.pages) стр." : "Текстовый слой, \(info.pages) стр."
        }
        return "В индексе \(info.indexedPages) из \(info.pages) стр."
    }

    private func addBooks(to collection: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Выберите учебники в формате PDF"
        guard panel.runModal() == .OK else { return }
        var paths = settings.literatureCollections[collection] ?? []
        for url in panel.urls where !paths.contains(url.path) { paths.append(url.path) }
        settings.literatureCollections[collection] = paths
        literature.startIndexing()
    }
}
