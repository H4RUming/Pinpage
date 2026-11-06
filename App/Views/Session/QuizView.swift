import PinpageCore
import SwiftUI

/// 퀴즈 풀기 (사전 퀴즈, 체크포인트 퀴즈, 최종 시험, 재시험). 자료와 AI 도우미는 보이지 않는다.
/// 답을 고칠 때마다 저장하므로 앱이 꺼져도 고른 답이 남는다.
struct QuizView: View {
    @Bindable var model: SessionModel
    let quiz: Quiz
    let attempt: QuizAttempt
    @State private var confirming = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(quiz.displayTitle).font(.title2.bold())
                        if attempt.attemptNumber > 1 {
                            Text("\(attempt.attemptNumber)번째 응시").foregroundStyle(.secondary)
                        }
                    }
                    Text(instructions).foregroundStyle(.secondary)
                }
                ForEach(Array(quiz.questions.enumerated()), id: \.element.id) { index, question in
                    QuestionCard(number: index + 1, question: question, response: binding(for: question.id))
                }
                HStack {
                    Text("\(answeredCount) / \(quiz.questions.count)문제 답함").foregroundStyle(.secondary)
                    Spacer()
                    Button("제출") { confirming = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .alert("제출할까요?", isPresented: $confirming) {
            Button("제출") { model.submitQuiz() }
            Button("취소", role: .cancel) {}
        } message: {
            let unanswered = quiz.questions.count - answeredCount
            Text(unanswered > 0 ? "답하지 않은 문제가 \(unanswered)개 있습니다. 제출하면 답을 고칠 수 없습니다." : "제출하면 답을 고칠 수 없습니다.")
        }
    }

    private var instructions: String {
        switch quiz.kind {
        case .pre:
            "학습을 시작하기 전에 지금 알고 있는 만큼 답하세요. 모르는 문제는 비워 두어도 됩니다."
        case .checkpoint:
            "자료를 보지 않고 답하세요. 제출하면 총점과 통과 여부만 알려 줍니다."
        case .final, .retest:
            "자료를 보지 않고 답하세요. 한 번만 제출할 수 있습니다."
        }
    }

    private var answeredCount: Int {
        quiz.questions.filter { !(model.responses[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    private func binding(for id: String) -> Binding<String> {
        Binding(get: { model.responses[id] ?? "" }, set: { model.responses[id] = $0 })
    }
}

private struct QuestionCard: View {
    let number: Int
    let question: QuizQuestion
    @Binding var response: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(number).").font(.headline)
                Text(question.prompt).font(.body)
                Spacer()
                if question.score > 1 {
                    Text("\(question.score)점").font(.caption).foregroundStyle(.secondary)
                }
            }
            switch question.type {
            case .multipleChoice:
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array((question.choices ?? []).enumerated()), id: \.offset) { index, choice in
                        let value = String(index + 1)
                        Button {
                            response = response == value ? "" : value
                        } label: {
                            Label(choice, systemImage: response == value ? "largecircle.fill.circle" : "circle")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 20)
            case .shortAnswer:
                TextField("답을 입력하세요", text: $response)
                    .textFieldStyle(.roundedBorder)
                    .padding(.leading, 20)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}
