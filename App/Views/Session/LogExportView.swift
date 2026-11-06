import AppKit
import PinpageCore
import SwiftUI

/// 로그 내보내기: 참가자 하나(기본) 또는 이 Mac의 전체 기록(진행자용)을 zip 파일 하나로 저장한다.
struct LogExportView: View {
    @Environment(\.dismiss) private var dismiss
    let model: SessionModel
    /// 미리 고를 참가자 (세션 요약 화면에서 열었을 때)
    let preselected: String?

    @State private var participants: [ExportParticipant] = []
    @State private var selection: LogExportScope?
    @State private var outcome: SessionModel.ExportOutcome?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("로그 내보내기").font(.title2.bold())
            if let outcome {
                saved(outcome)
            } else {
                chooser
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear(perform: load)
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("참가자 ID를 고르면 그 참가자의 세션과 세션 중 기록만 담습니다. 진행자가 정해 준 자기 ID를 고르세요.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(selection: $selection) {
                Section("참가자") {
                    if participants.isEmpty {
                        Text("아직 실험 세션 기록이 없습니다.").foregroundStyle(.secondary)
                    }
                    ForEach(participants) { participant in
                        HStack {
                            Text(participant.id).font(.body.monospaced().bold())
                            Text("세션 \(participant.sessionCount)개").foregroundStyle(.secondary)
                            Spacer()
                            Text(participant.lastStartedAt, format: .dateTime.month().day().hour().minute())
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .tag(LogExportScope.participant(participant.id))
                    }
                }
                Section("진행자용") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("이 Mac의 전체 기록")
                        Text("모든 참가자 ID와 세션 밖 기록(설정 탭의 연결 테스트 등)까지 담습니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(LogExportScope.all)
                }
            }
            .frame(height: 240)

            Text("zip 파일 안에는 manifest.json(앱 버전, 모델, 내보낸 시각, 파일별 SHA-256), events.jsonl(원본 이벤트), sessions.csv(세션 요약), quiz_items.csv(문항별 퀴즈 응답)가 들어 있습니다. API 키는 들어가지 않습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("저장…") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
    }

    private func saved(_ outcome: SessionModel.ExportOutcome) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("저장했습니다", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text(outcome.url.lastPathComponent)
                .font(.callout.monospaced())
                .textSelection(.enabled)
            Text("세션 \(outcome.sessionCount)개 · 이벤트 \(outcome.eventCount)개 · 퀴즈 응답 \(outcome.quizItemCount)줄")
                .foregroundStyle(.secondary)
            Text("SHA-256: \(String(outcome.sha256.prefix(16)))…")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("이 파일을 진행자에게 보내세요.")
                .font(.callout)
            HStack {
                Spacer()
                Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([outcome.url]) }
                Button("닫기") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func load() {
        participants = model.exportParticipants()
        if let preselected, participants.contains(where: { $0.id == preselected }) {
            selection = .participant(preselected)
        } else {
            selection = participants.first.map { .participant($0.id) } ?? .all
        }
    }

    private func save() {
        guard let selection else { return }
        error = nil
        do {
            outcome = try model.exportLog(selection)
        } catch {
            self.error = "내보내지 못했습니다: \(error.localizedDescription)"
        }
    }
}
