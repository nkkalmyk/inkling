import SwiftUI

/// Меню «Модель» на панели лекции: ручной выбор движка для новых запусков (SPEC, раздел 13, этап 8).
struct EngineModeMenu: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var settings = settings
        Menu {
            Picker("Модель", selection: $settings.engineMode) {
                ForEach(AppSettings.EngineMode.allCases) { Text(description($0)).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Настройки движков…") { openSettings() }
        } label: {
            Label(shortTitle, systemImage: icon)
                .labelStyle(.titleAndIcon)
        }
        .help("Каким движком распознавать, собирать и готовить материалы. Действует на новые запуски.")
    }

    private var claude: String { "Claude (\(settings.claudeModel.isEmpty ? "sonnet" : settings.claudeModel))" }
    private var codex: String { "Codex (не проверен вживую)" }
    private var local: String { "локальная (\(settings.ollamaModel))" }

    private func description(_ mode: AppSettings.EngineMode) -> String {
        switch mode {
        case .auto:
            let routing = EngineCenter.routing(mode: .auto, primary: settings.primaryEngine, fallback: settings.fallbackEngine)
            let main = name(routing.primary, capitalized: true)
            guard let spare = routing.fallback else { return "Авто: \(main)" }
            return "Авто: \(main), при лимите — \(name(spare, capitalized: false))"
        case .claudeOnly: return "Только \(claude)"
        case .codexOnly: return "Только \(codex)"
        case .localOnly: return "Только \(local)"
        }
    }

    private func name(_ engine: EngineID, capitalized: Bool) -> String {
        switch engine {
        case .claude: claude
        case .codex: codex
        case .ollama: capitalized ? local.capitalizedFirst : local
        }
    }

    private var shortTitle: String {
        switch settings.engineMode {
        case .auto: "Авто"
        case .claudeOnly: "Claude"
        case .codexOnly: "Codex"
        case .localOnly: "Локально"
        }
    }

    private var icon: String {
        switch settings.engineMode {
        case .auto: "arrow.triangle.branch"
        case .claudeOnly, .codexOnly: "cloud"
        case .localOnly: "desktopcomputer"
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Пометка на результате локальной модели: на плотной рукописи она ошибается заметно чаще Claude.
/// После ручной правки пометка снимается — текст уже проверен.
struct ReviewBadge: View {
    let engine: EngineID?
    var manuallyEdited = false

    var body: some View {
        if engine?.needsReview == true, !manuallyEdited {
            // Предупреждения в интерфейсе бесцветные; эту пометку пропускать нельзя, поэтому она выделена формой.
            Label("Сделано локальной моделью — проверьте", systemImage: "exclamationmark.triangle")
                .labelStyle(.titleAndIcon)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .padding(.horizontal, Spacing.s)
                .padding(.vertical, Spacing.xxs)
                .surface(.raised, radius: Radius.chip)
                .help("Локальная модель чаще ошибается в словах, числах и формулах и редко признаёт неразборчивое. "
                      + "Сверьте с оригиналом.")
        }
    }
}
