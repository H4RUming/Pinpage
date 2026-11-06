import PinpageCore
import SwiftUI

/// 진행 중인 세션: 위에 참가자·조건·타이머, 아래에 단계별 화면 (사전 퀴즈, 학습, 퀴즈).
struct SessionRunView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: SessionModel
    let session: ExperimentSession
    @State private var confirmingCheckpoint = false
    @State private var confirmingAbandon = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch session.phase {
            case .preQuiz, .quiz:
                if let quiz = model.currentQuiz, let attempt = model.attempt {
                    QuizView(model: model, quiz: quiz, attempt: attempt)
                } else {
                    ContentUnavailableView("퀴즈를 열 수 없습니다", systemImage: "exclamationmark.triangle",
                                           description: Text("세션을 중단하고 진행자에게 알려 주세요."))
                }
            case .studying:
                studying
            case .completed, .abandoned:
                EmptyView()
            }
        }
        .alert("체크포인트 퀴즈를 시작할까요?", isPresented: $confirmingCheckpoint) {
            Button("시작") { model.beginCheckpoint() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("제출할 때까지 자료와 AI 도우미를 볼 수 없습니다. 제출하면 총점과 통과 여부만 알려 줍니다.")
        }
        .alert("세션을 중단할까요?", isPresented: $confirmingAbandon) {
            Button("중단", role: .destructive) { model.abandon() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("중단한 세션은 이어서 할 수 없습니다. 진행자가 안내한 경우에만 중단하세요.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label(session.participantId, systemImage: "person.fill").font(.callout.bold())
            Text("\(session.condition.label) 조건 · \(session.kind.label)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            TimelineLabel(phase: session.phase, times: model.times)
            if session.kind == .learning && session.phase == .studying {
                Button("체크포인트 퀴즈") { confirmingCheckpoint = true }
                    .buttonStyle(.borderedProminent)
            }
            Menu {
                Button("세션 중단…", role: .destructive) { confirmingAbandon = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var studying: some View {
        VStack(spacing: 0) {
            if let result = model.lastCheckpoint {
                banner(
                    "체크포인트 퀴즈 \(model.checkpointAttempts)회차: \(result.earned)/\(result.total)점 (\(percent(result.ratio))). 통과 기준은 \(percent(result.threshold))입니다. 더 학습한 뒤 다시 응시하세요.",
                    icon: "arrow.counterclockwise.circle.fill", color: .orange)
            } else if let notice = model.notice {
                banner(notice, icon: "info.circle.fill", color: .blue)
            }
            if let library = app.libraryModel {
                let documents = model.indexedDocuments(setId: session.setId)
                if session.condition == .tool {
                    HStack(spacing: 0) {
                        StudyPanel(study: app.studyModel, library: library, showsSetPicker: false)
                            .frame(width: 440)
                        Divider()
                        MaterialsView(documents: documents, library: library.library,
                                      target: app.studyModel.viewerTarget, logger: app.eventLogger)
                    }
                    .onAppear { app.studyModel.startPracticeIfNeeded() }
                } else {
                    MaterialsView(documents: documents, library: library.library, target: nil, logger: app.eventLogger)
                }
            }
        }
    }

    private func banner(_ text: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.callout)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(color.opacity(0.08))
    }
}

/// 단계별 경과 시간 표시. 학습 세션은 사전 퀴즈를 뺀 학습 시간(통과까지 걸린 시간)을 보여준다.
private struct TimelineLabel: View {
    let phase: SessionPhase
    let times: StageTimes

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "timer")
            Text(label)
            Text(clockText(value)).monospacedDigit()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .help("앱이 켜져 있는 동안만 셉니다. 앱을 끄거나 Mac이 잠든 동안은 멈춥니다.")
    }

    private var label: String {
        switch phase {
        case .preQuiz: "사전 퀴즈"
        case .quiz: "퀴즈"
        default: "학습"
        }
    }

    private var value: Int {
        switch phase {
        case .preQuiz: times.preQuizMs
        default: times.learningMs
        }
    }
}
