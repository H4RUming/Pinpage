import PinpageCore
import SwiftUI

/// 실험 세션 탭: 진행 중인 세션이 있으면 진행 화면, 막 끝났으면 요약, 아니면 시작 화면.
struct SessionView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var session = app.sessionModel!

        Group {
            if let current = session.session {
                SessionRunView(model: session, session: current)
            } else if let summary = session.summary {
                SessionSummaryView(summary: summary) { session.dismissSummary() }
            } else {
                SessionStartView(model: session)
            }
        }
        .navigationTitle("실험 세션")
        .alert("확인이 필요합니다",
               isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
            Button("확인") {}
        } message: {
            Text(session.errorMessage ?? "")
        }
    }
}

/// 끝난 세션 요약.
private struct SessionSummaryView: View {
    let summary: SessionModel.Summary
    let dismiss: () -> Void

    var body: some View {
        let session = summary.session
        VStack(spacing: 18) {
            Image(systemName: session.endReason == "abandoned" ? "stop.circle" : "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(session.endReason == "abandoned" ? Color.secondary : Color.green)
            Text(title).font(.title2.bold())
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("참가자").foregroundStyle(.secondary)
                    Text("\(session.participantId) · \(session.condition.label) 조건 · \(session.kind.label)")
                }
                if let result = summary.result {
                    GridRow {
                        Text("점수").foregroundStyle(.secondary)
                        Text("\(result.earned) / \(result.total)점 (\(percent(result.ratio)))")
                    }
                }
                if session.kind == .learning {
                    GridRow {
                        Text("학습 시간").foregroundStyle(.secondary)
                        Text(clockText(session.times.learningMs))
                    }
                    GridRow {
                        Text("체크포인트 응시").foregroundStyle(.secondary)
                        Text("\(summary.checkpointAttempts)회")
                    }
                } else {
                    GridRow {
                        Text("응시 시간").foregroundStyle(.secondary)
                        Text(clockText(session.times.quizMs))
                    }
                }
            }
            Text("기록은 이 Mac에 저장되었습니다. 진행자의 안내에 따라 다음 단계를 진행하세요.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("확인", action: dismiss)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        switch summary.session.endReason {
        case "passed": "체크포인트 퀴즈를 통과했습니다"
        case "abandoned": "세션을 중단했습니다"
        default: "\(summary.session.kind.label)을 제출했습니다"
        }
    }
}

/// 밀리초를 "12:34" 또는 "1:02:03"으로.
func clockText(_ milliseconds: Int) -> String {
    let seconds = max(0, milliseconds) / 1000
    let (h, m, s) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
}

func percent(_ ratio: Double) -> String {
    "\(Int((ratio * 100).rounded()))%"
}
