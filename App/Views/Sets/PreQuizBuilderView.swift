import AppKit
import PinpageCore
import SwiftUI
import UniformTypeIdentifiers

/// 진행자용: 학습 세트로 사전 퀴즈를 만들어 검토한 뒤 퀴즈 파일로 저장한다.
/// 참가자 앱에서 만들지 않고 한 번 만든 파일을 모두에게 나눠 주므로 모든 참가자가 같은 문제를 푼다.
struct PreQuizBuilderView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let set: LearningSet
    @State private var model = PreQuizBuilderModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("사전 퀴즈 만들기").font(.title2.bold())
            Text("'\(set.name)' 세트의 자료에서 고르게 떨어진 위치를 골라 AI가 temperature 0으로 문제를 만듭니다. 객관식은 정답 번호를 한 번 더 검증합니다. 검토한 뒤 빼고 싶은 문제의 체크를 풀고 저장하세요.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                Stepper("문제 수: \(model.count)", value: $model.count, in: 1...30)
                    .fixedSize()
                Toggle("객관식", isOn: typeBinding(.multipleChoice))
                Toggle("단답형", isOn: typeBinding(.shortAnswer))
                Spacer()
                if model.isBuilding {
                    if let progress = model.progress {
                        ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                            .frame(width: 120)
                        Text("\(progress.done)/\(progress.total)").monospacedDigit().foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Button("중지") { model.cancel() }
                } else {
                    Button(model.drafts.isEmpty ? "만들기" : "다시 만들기") { model.build(app: app, setId: set.id) }
                        .disabled(model.types.isEmpty || app.studyModel.configurationIssue != nil)
                }
            }
            if let issue = app.studyModel.configurationIssue {
                Label(issue, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            }
            if let error = model.error {
                Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout).textSelection(.enabled)
            }

            List {
                ForEach(model.drafts) { draft in
                    DraftRow(draft: draft, included: Binding(
                        get: { model.included.contains(draft.id) },
                        set: { if $0 { model.included.insert(draft.id) } else { model.included.remove(draft.id) } }))
                }
            }
            .overlay {
                if model.drafts.isEmpty && !model.isBuilding {
                    ContentUnavailableView("아직 만든 문제가 없습니다", systemImage: "list.bullet.clipboard")
                }
            }

            HStack {
                if model.failureCount > 0 {
                    Text("검증에서 버린 시도 \(model.failureCount)개").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("닫기") { model.cancel(); dismiss() }
                Menu("저장") {
                    Button("새 퀴즈 파일로 저장…") { model.save(set: set, mergeIntoExisting: false) }
                    Button("기존 퀴즈 파일에 넣기…") { model.save(set: set, mergeIntoExisting: true) }
                }
                .fixedSize()
                .disabled(model.included.isEmpty || model.isBuilding)
            }
            Text("기존 퀴즈 파일에 넣으면 그 파일의 사전 퀴즈만 바꾸고 체크포인트·최종 시험은 그대로 둡니다. 문구를 고치려면 저장한 JSON 파일을 텍스트 편집기로 여세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 760, height: 640)
        .alert("저장했습니다", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("확인") {}
        } message: {
            Text(model.message ?? "")
        }
    }

    private func typeBinding(_ type: QuizQuestionType) -> Binding<Bool> {
        Binding(get: { model.types.contains(type) },
                set: { if $0 { model.types.insert(type) } else { model.types.remove(type) } })
    }
}

private struct DraftRow: View {
    let draft: PreQuizDraft
    @Binding var included: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: $included).labelsHidden()
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(draft.question.prompt).font(.body.bold())
                    Spacer()
                    Text("\(draft.question.type.label) · 난이도 \(draft.difficulty)").font(.caption).foregroundStyle(.secondary)
                }
                if let choices = draft.question.choices {
                    ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                        let correct = draft.question.answer == index + 1
                        Label(choice, systemImage: correct ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(correct ? .green : .primary)
                            .font(.callout)
                    }
                }
                if let answers = draft.question.answers {
                    Text("정답: " + answers.joined(separator: " / ")).font(.callout).foregroundStyle(.green)
                }
                Text("근거: \(draft.sourceLabel)").font(.caption).foregroundStyle(.secondary)
                ForEach(draft.quotes, id: \.self) { quote in
                    Text("“\(quote)”").font(.caption).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
        .textSelection(.enabled)
    }
}

@Observable @MainActor
final class PreQuizBuilderModel {
    var count = 10
    var types: Set<QuizQuestionType> = [.multipleChoice, .shortAnswer]
    private(set) var drafts: [PreQuizDraft] = []
    var included: Set<String> = []
    private(set) var progress: (done: Int, total: Int)?
    private(set) var failureCount = 0
    private(set) var isBuilding = false
    var error: String?
    var message: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    func build(app: AppModel, setId: String) {
        guard let library = app.libraryModel, let templates = try? app.promptTemplates.get(),
              let endpoint = try? app.settings.chatEndpoint() else { return }
        let settings = app.settings
        let client = OpenAIClient(endpoint: endpoint, timeoutSeconds: settings.network.requestTimeoutSeconds,
                                  retryPolicy: RetryPolicy(maxRetries: settings.network.maxRetries), recorder: app.callRecorder)
        let builder = PreQuizBuilder(database: library.library.database, client: client, templates: templates,
                                     request: StructuredRequest(settings: settings))
        let count = count
        let types = QuizQuestionType.allCases.filter(types.contains)
        isBuilding = true
        error = nil
        progress = nil
        task = Task {
            defer { isBuilding = false }
            do {
                let output = try await builder.build(setId: setId, count: count, types: types) { done, total in
                    await MainActor.run { self.progress = (done, total) }
                }
                guard !Task.isCancelled else { return }
                drafts = output.drafts
                included = Set(output.drafts.map(\.id))
                failureCount = output.failures.count
                if output.drafts.count < count {
                    error = "\(count)문제 중 \(output.drafts.count)문제만 만들었습니다 (자료가 짧거나 검증에서 버린 문제가 있음)."
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.error = (error as? LLMRequestError)?.message ?? error.localizedDescription
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isBuilding = false
    }

    func save(set: LearningSet, mergeIntoExisting: Bool) {
        let questions = drafts.filter { included.contains($0.id) }.enumerated().map { index, draft in
            var question = draft.question
            question.id = "pre-\(index + 1)"
            return question
        }
        let quiz = Quiz(kind: .pre, questions: questions)
        var file: QuizFile
        var suggestedName = "\(set.name) 사전 퀴즈.json"
        do {
            if mergeIntoExisting {
                let panel = NSOpenPanel()
                panel.title = "사전 퀴즈를 넣을 퀴즈 파일"
                panel.allowedContentTypes = [.json]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                file = try QuizFile.load(try Data(contentsOf: url)).replacing(quiz)
                suggestedName = url.lastPathComponent
            } else {
                let stamp = Date().formatted(.iso8601.year().month().day())
                file = QuizFile(id: "\(set.name)-\(stamp)", title: "\(set.name) 퀴즈", quizzes: [quiz])
            }
            let panel = NSSavePanel()
            panel.title = "퀴즈 파일 저장"
            panel.nameFieldStringValue = suggestedName
            panel.allowedContentTypes = [.json]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let data = try file.encoded()
            try data.write(to: url, options: .atomic)
            let missing = [QuizKind.checkpoint, .final].filter { file.quiz($0) == nil }.map(\.label)
            message = "\(url.lastPathComponent)에 사전 퀴즈 \(questions.count)문제를 저장했습니다."
                + (missing.isEmpty ? "" : "\n이 파일에는 아직 \(missing.joined(separator: ", "))가 없습니다. docs/quiz-format.md를 보고 추가하세요.")
                + "\nSHA-256: \(QuizFile.sha256(data).prefix(16))…"
        } catch {
            self.error = error.localizedDescription
        }
    }
}
