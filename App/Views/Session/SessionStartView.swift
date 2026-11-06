import PinpageCore
import SwiftUI

/// 세션 시작: 참가자 ID, 세션 종류, 조건, 학습 세트, 퀴즈 파일.
struct SessionStartView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: SessionModel
    @State private var confirming = false

    var body: some View {
        let blockers = model.startBlockers
        Form {
            Section {
                TextField("참가자 ID", text: $model.participantId, prompt: Text("예: P01"))
            } header: {
                Text("참가자")
            } footer: {
                Text("실명 대신 진행자가 정해 준 ID를 입력하세요. 영문, 숫자, -, _만 쓸 수 있습니다.")
            }

            Section("세션") {
                Picker("세션 종류", selection: $model.kind) {
                    ForEach(SessionKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("조건", selection: $model.condition) {
                    ForEach(ExperimentCondition.allCases, id: \.self) { condition in
                        Text(condition == .tool ? "도구 (AI 사용)" : "대조 (자료만)").tag(condition)
                    }
                }
                .pickerStyle(.segmented)
                Picker("학습 세트", selection: $model.setId) {
                    Text("선택 안 함").tag(String?.none)
                    ForEach(app.libraryModel?.sets ?? []) { set in Text(set.name).tag(Optional(set.id)) }
                }
            }

            Section {
                HStack {
                    Picker("퀴즈 파일", selection: $model.quizSetId) {
                        if model.quizSets.isEmpty { Text("없음").tag(String?.none) }
                        ForEach(model.quizSets) { record in
                            Text("\(record.title) (\(record.fileName))").tag(Optional(record.id))
                        }
                    }
                    Button("불러오기…") { model.importQuizFile() }
                }
                if let file = model.selectedQuizFile, let record = model.quizSets.first(where: { $0.id == model.quizSetId }) {
                    ForEach(file.quizzes, id: \.kind) { quiz in
                        LabeledContent(quiz.displayTitle, value: "\(quiz.questions.count)문제 · \(quiz.totalPoints)점")
                    }
                    LabeledContent("SHA-256") {
                        Text(String(record.sha256.prefix(16)))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("퀴즈 파일")
            } footer: {
                Text("진행자가 나눠 준 퀴즈 파일을 불러오세요. 모든 참가자가 같은 파일을 쓰는지 SHA-256 앞자리로 확인할 수 있습니다.")
            }

            Section {
                ForEach(blockers, id: \.self) { issue in
                    Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                }
                ForEach(model.startWarnings, id: \.self) { warning in
                    Label(warning, systemImage: "info.circle").foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("세션 시작") { confirming = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(!blockers.isEmpty)
                }
            } footer: {
                Text(flowDescription)
            }

            if !model.pastSessions.isEmpty {
                Section("이 Mac의 지난 세션") {
                    ForEach(model.pastSessions) { past in
                        PastSessionRow(session: past)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.reloadLists() }
        .alert("세션을 시작할까요?", isPresented: $confirming) {
            Button("시작") { model.start() }
            Button("취소", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    private var flowDescription: String {
        switch model.kind {
        case .learning:
            "사전 퀴즈(퀴즈 파일에 있으면)를 먼저 풀고 학습을 시작합니다. 준비가 되면 체크포인트 퀴즈를 응시하고, 통과 기준(\(percent(app.settings.learning.quizPassThreshold))) 이상이면 세션이 끝납니다. 세션 중에는 설정을 바꿀 수 없습니다."
        case .final, .retest:
            "\(model.kind.label)을 한 번 응시합니다. 시험 중에는 자료와 AI 도우미를 볼 수 없습니다."
        }
    }

    private var confirmMessage: String {
        let id = model.participantId.trimmingCharacters(in: .whitespacesAndNewlines)
        let setName = app.libraryModel?.sets.first { $0.id == model.setId }?.name ?? "없음"
        return "참가자 \(id) · \(model.condition.label) 조건 · \(model.kind.label)\n학습 세트: \(setName)\n시작하면 경과 시간을 재기 시작합니다."
    }
}

private struct PastSessionRow: View {
    let session: ExperimentSession

    var body: some View {
        HStack {
            Text(session.participantId).font(.callout.monospaced().bold())
            Text("\(session.condition.label) · \(session.kind.label)").foregroundStyle(.secondary)
            Spacer()
            Text(result).foregroundStyle(.secondary)
            Text(session.startedAt, format: .dateTime.month().day().hour().minute())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
    }

    private var result: String {
        switch session.endReason {
        case "passed": "통과 · \(clockText(session.times.learningMs))"
        case "completed": "제출"
        case "abandoned": "중단"
        default: session.phase.isActive ? "진행 중" : "-"
        }
    }
}
