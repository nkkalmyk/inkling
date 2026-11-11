import AppKit
import SwiftUI

struct ProcessingSettings: View {
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
                               value: "\(settings.chunkThresholdChars.formatted(.number.locale(UIFormat.locale))) симв.")
            }
            Toggle("Готовить учебные материалы сразу после сборки", isOn: $settings.autoStudyMaterials)
            Toggle("Сохранять временные папки при ошибке (для отладки)", isOn: $settings.keepTempFoldersOnError)
        }
        .formStyle(.grouped)
    }
}
