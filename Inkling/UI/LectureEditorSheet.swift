import SwiftUI

/// Создание и изменение лекции: предмет, тема, дата (SPEC, раздел 4, пункт 1).
struct LectureEditorSheet: View {
    enum Mode {
        case create(subject: String?)
        case edit(UUID)
    }

    private static let newSubjectTag = "\u{0}new-subject"

    @Environment(Library.self) private var library

    let mode: Mode
    @State private var subjectChoice = ""
    @State private var newSubjectName = ""
    @State private var topic = ""
    @State private var date = Date()
    @State private var loaded = false
    @FocusState private var topicFocused: Bool

    var body: some View {
        FormSheet(title: isEditing ? "Изменить лекцию" : "Новая лекция",
                  subtitle: isEditing ? nil : "Фото конспекта и слайды добавляются внутри лекции.",
                  confirmTitle: isEditing ? "Сохранить" : "Создать", canConfirm: canSave, confirm: save) {
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

    /// `true` — лист можно закрыть; при ошибке он остаётся открытым, сообщение показывает Library.
    private func save() -> Bool {
        let day = CalendarDate(date)
        switch mode {
        case .create:
            return library.createLecture(subject: resolvedSubject, topic: topic, date: day)
        case .edit(let id):
            return library.updateLecture(id: id, subject: resolvedSubject, topic: topic, date: day)
        }
    }
}

/// Создание и переименование предмета.
struct SubjectNameSheet: View {
    enum Mode {
        case create
        case rename(String)
    }

    @Environment(Library.self) private var library

    let mode: Mode
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        FormSheet(title: title, width: SheetWidth.compact, confirmTitle: actionTitle,
                  canConfirm: !name.trimmingCharacters(in: .whitespaces).isEmpty, confirm: save) {
            TextField("Название предмета", text: $name)
                .focused($focused)
        }
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

    private func save() -> Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch mode {
        case .create: return library.createSubject(named: name)
        case .rename(let old): return library.renameSubject(old, to: name)
        }
    }
}
