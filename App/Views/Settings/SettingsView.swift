import PinpageCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let issues = model.settings.validate()

        Form {
            if let banner = model.banner {
                Section {
                    HStack(alignment: .top) {
                        Label(banner, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                        Spacer()
                        Button("닫기") { model.banner = nil }
                    }
                }
            }
            if model.isSettingsLocked {
                Section {
                    Label("실험 세션 진행 중에는 모델과 주요 설정을 바꿀 수 없습니다.", systemImage: "lock.fill")
                }
            }
            if !issues.isEmpty {
                Section("확인이 필요한 값") {
                    ForEach(issues, id: \.description) { issue in
                        Label(issue.description, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    }
                }
            }

            EndpointSection(role: .chat)
            EmbeddingModeSection()
            if model.settings.embedding.mode == .remote {
                EndpointSection(role: .embedding)
            }
            ValueSections()
            SettingsFileSection()
            RecentEventsSection()
        }
        .formStyle(.grouped)
        .navigationTitle("설정")
        .alert(
            model.alert?.title ?? "",
            isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
            presenting: model.alert
        ) { _ in
            Button("확인") {}
        } message: { alert in
            Text(alert.message)
        }
    }
}

/// 진행자 확인용: 최근 이벤트 로그.
private struct RecentEventsSection: View {
    @Environment(AppModel.self) private var model
    @State private var events: [EventRecord] = []

    var body: some View {
        Section {
            if events.isEmpty {
                Text("기록된 이벤트가 없습니다.").foregroundStyle(.secondary)
            }
            ForEach(events, id: \.seq) { event in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("#\(event.seq ?? 0)").monospacedDigit().foregroundStyle(.secondary)
                        Text(event.type).font(.callout.monospaced().bold())
                        Spacer()
                        Text(event.timestamp).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Text(event.payload)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
        } header: {
            HStack {
                Text("최근 이벤트")
                Spacer()
                Button("새로고침") { reload() }.font(.caption)
            }
        } footer: {
            Text("이벤트는 일어나는 즉시 이 Mac의 DB에 기록됩니다 (시각은 UTC). 실험 전에 기록이 남는지 확인하세요.")
        }
        .onAppear { reload() }
    }

    private func reload() {
        events = (try? model.eventLogger?.recent(limit: 30)) ?? []
    }
}

private struct SettingsFileSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            HStack {
                Button("설정 내보내기…") { model.exportSettings() }
                Button("설정 불러오기…") { model.importSettings() }
                    .disabled(model.isSettingsLocked)
            }
            LabeledContent("앱 버전", value: model.appInfo.displayVersion)
            if let url = model.settingsFileURL {
                LabeledContent("데이터 폴더") {
                    Button("Finder에서 보기") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
        } header: {
            Text("설정 파일")
        } footer: {
            Text("진행자가 내보낸 설정 파일을 불러오면 모든 참가자가 같은 모델과 값으로 실험할 수 있습니다. API 키는 내보내지 않으며, 불러올 때도 이 Mac에 입력해 둔 키를 그대로 둡니다.")
        }
    }
}
