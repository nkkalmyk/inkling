import AppKit
import SwiftUI

/// Учебники для учебной сборки: коллекции книг (PDF), привязка предметов, индекс с распознаванием сканов.
struct LiteratureSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Library.self) private var library
    @Environment(LiteratureCenter.self) private var literature
    @State private var newCollection = ""
    @State private var confirmClear = false

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
                    Button("Очистить индекс…", role: .destructive) { confirmClear = true }
                        .disabled(literature.isIndexing)
                        .help(literature.isIndexing ? "Сначала остановите индексацию" : "Удалить индекс; книги останутся на диске")
                        .confirmationDialog("Очистить индекс учебников?", isPresented: $confirmClear, titleVisibility: .visible) {
                            Button("Очистить", role: .destructive) { Task { await literature.clearIndex() } }
                            Button("Отмена", role: .cancel) {}
                        } message: {
                            Text("Книги останутся на диске и в коллекциях, но распознанный текст пропадёт: индекс придётся строить заново, сканы распознаются несколько минут.")
                        }
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
            IconButton("Убрать книгу", systemImage: "minus.circle", help: "Убрать книгу из коллекции и индекса") {
                settings.literatureCollections[collection]?.removeAll { $0 == path }
                literature.removeFromIndex(path: path)
            }
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
