import SwiftUI

// MARK: Вопросы

private enum QuestionsItem: Hashable {
    case summary, terms
    case question(String)
}

struct QuestionsView: View {
    @Environment(StudyCenter.self) private var study
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let lecture: LectureRecord
    let showNotes: () -> Void

    @State private var typeFilter: StudyMaterials.QuestionType?
    @State private var difficultyFilter: StudyMaterials.Difficulty?
    @State private var selection: QuestionsItem? = .summary
    @State private var revealed: Set<String> = []
    @State private var editing: EditTarget?
    @FocusState private var listFocused: Bool
    @Environment(\.isActiveTab) private var isActive

    var body: some View {
        StudyContainer(lecture: lecture, showNotes: showNotes) { materials, progress in
            let items = materials.questions.filter {
                (typeFilter == nil || $0.type == typeFilter) && (difficultyFilter == nil || $0.difficulty == difficultyFilter)
            }
            VStack(spacing: 0) {
                HSplitView {
                    VStack(spacing: 0) {
                        filters
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Spacing.l)
                            .padding(.vertical, Spacing.s)
                        list(materials: materials, items: items, progress: progress)
                    }
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 360)
                    detail(materials: materials, progress: progress)
                        .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .sheet(item: $editing) { target in
                StudyItemEditor(target: target, materials: materials) { updated in
                    study.saveEdited(updated, lectureID: lecture.id)
                }
            }
        }
        .onChange(of: isActive, initial: true) { if isActive { listFocused = true } }
    }

    private var filters: some View {
        HStack(spacing: Spacing.s) {
            Picker("Тип", selection: $typeFilter) {
                Text("Все типы").tag(StudyMaterials.QuestionType?.none)
                ForEach(StudyMaterials.QuestionType.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
            }
            Picker("Сложность", selection: $difficultyFilter) {
                Text("Любая сложность").tag(StudyMaterials.Difficulty?.none)
                ForEach(StudyMaterials.Difficulty.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
            }
        }
        .labelsHidden()
        .controlSize(.small)
    }

    private func list(materials: StudyMaterials, items: [StudyMaterials.Question], progress: StudyProgress) -> some View {
        List(selection: $selection) {
            Section {
                Label("Кратко", systemImage: "text.alignleft").tag(QuestionsItem.summary)
                if !materials.terms.isEmpty {
                    Label("Термины (\(materials.terms.count))", systemImage: "character.book.closed")
                        .tag(QuestionsItem.terms)
                }
            }
            Section("Вопросы (\(items.count))") {
                ForEach(items) { question in
                    let flagged = progress.flagged.contains(question.id)
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(MathText.preview(question.question))
                            .lineLimit(2)
                        HStack(spacing: Spacing.xxs) {
                            // Пометка видна не только прозрачностью: значок и подпись для VoiceOver.
                            if flagged {
                                Image(systemName: "flag.fill").accessibilityLabel("Помечен как ошибочный")
                            }
                            Text("\(question.type.title) · \(question.difficulty.title)")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, Spacing.xxs)
                    .opacity(flagged ? 0.5 : 1)
                    .tag(QuestionsItem.question(question.id))
                }
            }
        }
        .listStyle(.sidebar)
        .focused($listFocused)
        .onKeyPress(.space) {
            guard isActive, case .question(let id) = selection else { return .ignored }
            toggleReveal(id)
            return .handled
        }
    }

    @ViewBuilder
    private func detail(materials: StudyMaterials, progress: StudyProgress) -> some View {
        ScrollView {
            Group {
                switch selection {
                case .summary, nil:
                    summary(materials)
                case .terms:
                    terms(materials)
                case .question(let id):
                    if let question = materials.questions.first(where: { $0.id == id }) {
                        questionCard(question, flagged: progress.flagged.contains(question.id))
                    }
                }
            }
            .padding(Spacing.xxl)
            .frame(maxWidth: ReadingWidth.focused, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    /// «Кратко» одним фрагментом: пункты с формулами иначе дают по веб-вью на каждый пункт,
    /// и вкладка открывается рывком. Маркеры списка — в цвете акцента (notes.css).
    private func summary(_ materials: StudyMaterials) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Кратко").font(.sectionTitle)
            MathText(markdown: materials.summary.map { "- " + $0.replacingOccurrences(of: "\n", with: " ") }
                .joined(separator: "\n"))
        }
    }

    /// «Термины» одним фрагментом по той же причине.
    private func terms(_ materials: StudyMaterials) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Термины").font(.sectionTitle)
            MathText(markdown: materials.terms.map { "**\($0.term)**  \n\($0.definition)" }.joined(separator: "\n\n"))
        }
    }

    private func questionCard(_ q: StudyMaterials.Question, flagged: Bool) -> some View {
        let isRevealed = revealed.contains(q.id)
        return VStack(alignment: .leading, spacing: Spacing.l) {
            HStack(spacing: Spacing.s) {
                Chip(q.type.title)
                Chip(q.difficulty.title, style: .accent)
                if flagged { Chip("Ошибка в вопросе", style: .error) }
                Spacer()
                IconButton("Изменить вопрос", systemImage: "pencil") { editing = .question(q.id) }
                FlagButton(lectureID: lecture.id, itemID: q.id, flagged: flagged)
            }
            MathText(markdown: q.question, large: true)
            if isRevealed {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("Ответ").font(.label).foregroundStyle(.secondary)
                    MathText(markdown: q.answer)
                    if let solution = q.solution, !solution.isEmpty {
                        Text("Решение").font(.label).foregroundStyle(.secondary).padding(.top, Spacing.xs)
                        MathText(markdown: solution)
                    }
                }
                .padding(Spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .surface(.studyRaised)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
            HStack {
                Button(isRevealed ? "Скрыть ответ" : "Показать ответ") { toggleReveal(q.id) }
                Spacer()
                Text("Пробел — ответ, ↑↓ — другой вопрос").font(.caption).foregroundStyle(.secondary)
            }
        }
        .opacity(flagged ? 0.6 : 1)
    }

    private func toggleReveal(_ id: String) {
        withMotion(.standard, reduceMotion: reduceMotion) {
            if revealed.contains(id) { revealed.remove(id) } else { revealed.insert(id) }
        }
    }
}
