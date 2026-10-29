import PinpageCore
import SwiftUI

/// 학습 화면: 왼쪽에 연습 문제·힌트·질문, 오른쪽에 근거 PDF.
struct StudyView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let library = app.libraryModel {
            HStack(spacing: 0) {
                StudyPanel(study: app.studyModel, library: library)
                    .frame(width: 440)
                Divider()
                PDFViewerPane(target: app.studyModel.viewerTarget)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("학습")
            .onAppear { app.studyModel.startPracticeIfNeeded() }
            .onChange(of: library.selectedSetId) { app.studyModel.startPracticeIfNeeded() }
        } else {
            ContentUnavailableView("자료 DB를 열 수 없습니다", systemImage: "exclamationmark.triangle")
        }
    }
}

private struct StudyPanel: View {
    @Bindable var study: StudyModel
    @Bindable var library: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("학습 세트", selection: $library.selectedSetId) {
                    ForEach(library.sets) { set in Text(set.name).tag(Optional(set.id)) }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
            }

            if let reason = study.unavailableReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ProblemCard(study: study)
                        ForEach(study.entries) { entry in
                            EntryCard(entry: entry, study: study).id(entry.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: study.entries.count) {
                    if let last = study.entries.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }

            HStack(alignment: .bottom) {
                TextField("자료에 대해 질문하세요", text: $study.question, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit { study.ask() }
                Button("질문") { study.ask() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(study.question.trimmingCharacters(in: .whitespaces).isEmpty || study.isBusy)
            }
        }
        .padding(16)
    }
}

/// AI 연습 문제: 문제, 답안 입력, 채점 결과, 힌트.
private struct ProblemCard: View {
    @Bindable var study: StudyModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let problem = study.currentProblem {
                HStack {
                    Text("연습 문제 \(study.problemNumber)").font(.headline)
                    Text("\(problem.type.label) · \(difficultyLabel(problem.difficulty))")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                Text(problem.question).textSelection(.enabled)
                answerInput(problem)
                HStack {
                    Button("제출") { study.submitAnswer() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSubmit(problem))
                    if study.isGrading { ProgressView().controlSize(.small); Text("채점 중…").foregroundStyle(.secondary) }
                    Spacer()
                    Button(study.isSolved ? "다음 문제" : "건너뛰기") { study.nextProblem() }
                        .disabled(study.isGrading || study.isGeneratingProblem)
                }
                if let last = study.attempts.last {
                    GradeView(graded: last, problem: problem, attemptCount: study.attempts.count, study: study)
                }
                if !study.isSolved { hintRow }
            } else if study.isGeneratingProblem {
                HStack { ProgressView().controlSize(.small); Text("자료에서 연습 문제를 만드는 중…").foregroundStyle(.secondary) }
            } else if study.unavailableReason == nil {
                Button("연습 문제 시작") { study.nextProblem() }
            }
            if let error = study.problemError {
                Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout).textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func answerInput(_ problem: PracticeProblem) -> some View {
        switch problem.type {
        case .multipleChoice:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(problem.choices.enumerated()), id: \.offset) { index, choice in
                    Button {
                        study.selectedChoice = index
                    } label: {
                        Label(choice, systemImage: study.selectedChoice == index ? "largecircle.fill.circle" : "circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(study.isSolved)
                }
            }
        case .shortAnswer:
            TextField("답을 입력하세요", text: $study.answerText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { study.submitAnswer() }
                .disabled(study.isSolved)
        case .essay:
            TextEditor(text: $study.answerText)
                .font(.body)
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .disabled(study.isSolved)
        }
    }

    private var hintRow: some View {
        HStack {
            if study.nextHintLevel <= study.hintLevelCount {
                Button("힌트 \(study.nextHintLevel)단계") { study.requestHint() }
                    .disabled(study.isBusy)
                Text(hintDescription(study.nextHintLevel)).font(.caption).foregroundStyle(.secondary)
            } else {
                Label("모든 힌트를 봤습니다", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func canSubmit(_ problem: PracticeProblem) -> Bool {
        guard !study.isGrading, !study.isSolved else { return false }
        return problem.type == .multipleChoice
            ? study.selectedChoice != nil
            : !study.answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func difficultyLabel(_ level: Int) -> String {
        switch level {
        case 1: "기초"
        case 3: "심화"
        default: "보통"
        }
    }

    private func hintDescription(_ level: Int) -> String {
        switch level {
        case 1: "읽어야 할 위치"
        case 2: "해당 부분 설명"
        default: "정답과 풀이"
        }
    }
}

/// 채점 결과: 맞음/부분 정답/틀림, 피드백, 다시 읽어 볼 곳.
private struct GradeView: View {
    let graded: StudyModel.GradedAttempt
    let problem: PracticeProblem
    let attemptCount: Int
    let study: StudyModel

    var body: some View {
        let attempt = graded.attempt
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(attempt.verdict.label, systemImage: icon(attempt.verdict))
                    .font(.callout.bold())
                    .foregroundStyle(color(attempt.verdict))
                if attempt.verdict == .partial {
                    Text("\(Int((attempt.score * 100).rounded()))점").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(attemptCount)번째 제출").font(.caption2).foregroundStyle(.tertiary)
            }
            if !attempt.feedback.isEmpty {
                Text(attempt.feedback).font(.callout).textSelection(.enabled)
            }
            if attempt.verdict == .correct, problem.type != .multipleChoice {
                Text("모범 답안: \(problem.modelAnswer)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if !graded.missed.isEmpty {
                Text("다시 읽어 볼 곳").font(.caption).foregroundStyle(.secondary)
                ForEach(graded.missed) { missed in
                    Button {
                        study.show(missed)
                    } label: {
                        Label(missed.label, systemImage: missed.chunk.source == .ocr ? "doc.viewfinder" : "doc.text")
                            .font(.callout).lineLimit(1).truncationMode(.middle)
                    }
                    .buttonStyle(.link)
                }
                Text("읽어 본 뒤 다시 답해 보세요.").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color(attempt.verdict).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func icon(_ verdict: Verdict) -> String {
        switch verdict {
        case .correct: "checkmark.circle.fill"
        case .partial: "circle.lefthalf.filled"
        case .incorrect: "xmark.circle.fill"
        }
    }

    private func color(_ verdict: Verdict) -> Color {
        switch verdict {
        case .correct: .green
        case .partial: .orange
        case .incorrect: .red
        }
    }
}

private struct EntryCard: View {
    let entry: StudyModel.Entry
    let study: StudyModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch entry.kind {
            case .question(let text):
                Label(text, systemImage: "person.fill").font(.callout.bold())
            case .hint(let level):
                Label("힌트 \(level)단계", systemImage: "lightbulb.fill").font(.callout.bold()).foregroundStyle(.orange)
            }

            if let error = entry.error {
                Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red).textSelection(.enabled)
            } else if let result = entry.result {
                body(for: result)
            } else {
                HStack { ProgressView().controlSize(.small); Text("자료를 찾아 답하는 중…").foregroundStyle(.secondary) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func body(for result: GroundedResult) -> some View {
        switch result.status {
        case .notInMaterials:
            Label("자료에 없음", systemImage: "questionmark.folder").font(.body.bold())
            Text(notInMaterialsDetail(result)).font(.caption).foregroundStyle(.secondary)
        case .answered:
            if result.kind == .hint(level: 1) {
                Text("다음 위치를 읽어 보세요.")
            } else if !result.text.isEmpty {
                Text(result.text).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(StudyModel.grouped(result.citations), id: \.first!.source) { group in
                    let first = group[0]
                    Button {
                        study.show(group, requestId: entry.requestId)
                    } label: {
                        Label(first.label, systemImage: first.hit.chunk.source == .ocr ? "doc.viewfinder" : "doc.text")
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.link)
                    .help(group.allSatisfy { $0.quote.isEmpty }
                          ? first.hit.chunk.text
                          : group.map { "“\($0.quote)”" }.joined(separator: "\n"))
                }
            }
        }
        Text(footer(result)).font(.caption2).foregroundStyle(.tertiary)
    }

    private func notInMaterialsDetail(_ result: GroundedResult) -> String {
        switch result.notInMaterialsReason {
        case "근거 확인 실패": "모델이 답했지만 자료에서 근거를 확인할 수 없어 보여주지 않습니다."
        case "검색된 자료 없음": "이 세트에 색인된 자료가 없습니다."
        default: "학습 자료에서 이 내용을 찾지 못했습니다."
        }
    }

    private func footer(_ result: GroundedResult) -> String {
        var parts = ["검색 \(result.hits.count)개", result.usedEmbedding ? "하이브리드" : "키워드 검색"]
        if result.latencyMs > 0 { parts.append(String(format: "응답 %.1f초", Double(result.latencyMs) / 1000)) }
        return parts.joined(separator: " · ")
    }
}
