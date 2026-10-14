import SwiftUI

/// Создание и изменение лекции: предмет, тема, дата (SPEC, раздел 4, пункт 1).
struct LectureEditorSheet: View {
    enum Mode {
        case create(subject: String?)
        case edit(UUID)
    }

    private static let newSubjectTag = "\u{0}new-subject"

    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    let mode: Mode
    @State private var subjectChoice = ""
    @State private var newSubjectName = ""
    @State private var topic = ""
    @State private var date = Date()
    @State private var loaded = false
    @FocusState private var topicFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEditing ? "Изменить лекцию" : "Новая лекция")
                .font(.title2.weight(.semibold))

            Form {
                Picker("Предмет", selection: $subjectChoice) {
                    ForEach(library.subjectNames, id: \.self) { Text($0).tag($0) }
                    Divider()
                    Text("Новый предмет…").tag(Self.newSubjectTag)
                }
                if subjectChoice == Self.newSubjectTag {
                    TextField("Название предмета", text: $newSubjectName)
                }
                TextField("Тема", text: $topic, prompt: Text("Например, Окислительно-восстановительные реакции"))
                    .focused($topicFocused)
                DatePicker("Дата", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.field)
            }
            .formStyle(.columns)

            HStack {
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Сохранить" : "Создать") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear(perform: load)
    }

    private var isEditing: Bool {
        if case .edit = mode { true } else { false }
    }

    private var resolvedSubject: String {
        subjectChoice == Self.newSubjectTag ? newSubjectName : subjectChoice
    }

    private var canSave: Bool {
        !resolvedSubject.trimmingCharacters(in: .whitespaces).isEmpty
            && !topic.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        switch mode {
        case .create(let subject):
            subjectChoice = subject ?? library.subjectNames.first ?? Self.newSubjectTag
            date = CalendarDate.today.date()
        case .edit(let id):
            guard let lecture = library.lecture(id: id) else { return }
            subjectChoice = lecture.meta.subject
            topic = lecture.meta.topic
            date = lecture.meta.date.date()
        }
        if !library.subjectNames.contains(subjectChoice) && subjectChoice != Self.newSubjectTag {
            newSubjectName = subjectChoice
            subjectChoice = Self.newSubjectTag
        }
        topicFocused = true
    }

    private func save() {
        let day = CalendarDate(date)
        let ok: Bool
        switch mode {
        case .create:
            ok = library.createLecture(subject: resolvedSubject, topic: topic, date: day)
        case .edit(let id):
            ok = library.updateLecture(id: id, subject: resolvedSubject, topic: topic, date: day)
        }
        if ok { dismiss() }
    }
}

/// Создание и переименование предмета.
struct SubjectNameSheet: View {
    enum Mode {
        case create
        case rename(String)
    }

    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    let mode: Mode
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.weight(.semibold))
            TextField("Название предмета", text: $name)
                .focused($focused)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            if case .rename(let old) = mode { name = old }
            focused = true
        }
    }

    private var title: String {
        if case .rename = mode { "Переименовать предмет" } else { "Новый предмет" }
    }

    private var actionTitle: String {
        if case .rename = mode { "Переименовать" } else { "Создать" }
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let ok: Bool
        switch mode {
        case .create: ok = library.createSubject(named: name)
        case .rename(let old): ok = library.renameSubject(old, to: name)
        }
        if ok { dismiss() }
    }
}
