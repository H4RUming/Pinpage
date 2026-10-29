import AppKit
import PinpageCore
import SwiftUI

/// 임베딩 방식 선택과 앱 내장 모델 설치·준비 상태.
struct EmbeddingModeSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let manager = model.embeddingManager
        let locked = model.isSettingsLocked

        Section {
            Picker("방식", selection: $model.settings.embedding.mode) {
                ForEach(EmbeddingMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .disabled(locked)

            if model.settings.embedding.mode == .builtin {
                StatusRow(status: manager.status)
                HStack {
                    switch manager.status {
                    case .notInstalled, .failed:
                        Button("모델 내려받기 (약 585MB)") { manager.download(settings: model.settings) }
                        Button("폴더에서 설치…") { chooseFolder() }
                    case .downloading, .verifying:
                        Button("취소") { manager.cancel() }
                    default:
                        EmptyView()
                    }
                }
                Picker("연산 장치", selection: $model.settings.embedding.computeUnit) {
                    ForEach(EmbeddingComputeUnit.allCases, id: \.self) { unit in
                        Text(unit == .gpu ? "GPU (기본, 기준값과 같은 결과)" : unit.label).tag(unit)
                    }
                }
                .disabled(locked)
                Picker("차원", selection: $model.settings.embedding.dimension) {
                    ForEach(SettingsLimits.embeddingDimensions, id: \.self) { d in
                        Text(d == 768 ? "768 (기본)" : "\(d)").tag(d)
                    }
                }
                .disabled(locked)
                DisclosureGroup("모델 저장소와 버전") {
                    TextField("저장소", text: $model.settings.embedding.modelRepo, prompt: Text("사용자/저장소"))
                    TextField("버전 (커밋 해시)", text: $model.settings.embedding.modelRevision)
                        .font(.body.monospaced())
                    TextField("manifest.json SHA-256", text: $model.settings.embedding.modelManifestSHA256)
                        .font(.body.monospaced())
                }
                .disabled(locked)
            } else if model.settings.embedding.mode == .remote {
                Text("아래 '임베딩 API'에서 서버와 모델을 지정하세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = manager.promptsError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        } header: {
            Text("임베딩")
        } footer: {
            Text("임베딩 설정(방식, 모델, 연산 장치, 차원)이 바뀌면 학습 세트를 다시 색인해야 합니다. 앱 내장 모델은 처음 한 번 내려받으며, 인터넷이 없으면 진행자가 준 모델 폴더에서 설치할 수 있습니다.")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "임베딩 모델 폴더 선택"
        panel.message = "manifest.json이 들어 있는 모델 폴더를 고르세요."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.embeddingManager.installFromFolder(url, settings: model.settings)
    }
}

private struct StatusRow: View {
    let status: EmbeddingManager.Status

    var body: some View {
        LabeledContent("모델 상태") {
            switch status {
            case .off:
                Text("사용 안 함").foregroundStyle(.secondary)
            case .notInstalled:
                Label("설치되지 않음", systemImage: "arrow.down.circle").foregroundStyle(.orange)
            case .downloading(let fraction, let detail):
                VStack(alignment: .trailing) {
                    ProgressView(value: fraction).frame(width: 220)
                    Text("내려받는 중 \(Int(fraction * 100))% · \(detail)").font(.caption).foregroundStyle(.secondary)
                }
            case .verifying(let file):
                HStack { ProgressView().controlSize(.small); Text("검증 중 · \(file)").foregroundStyle(.secondary) }
            case .preparing(let fraction):
                VStack(alignment: .trailing) {
                    ProgressView(value: fraction).frame(width: 220)
                    Text("모델 준비 중 (처음 한 번은 1분 정도 걸립니다)").font(.caption).foregroundStyle(.secondary)
                }
            case .ready:
                Label("준비 완료", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .remote:
                Text("원격 API 사용").foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }
}
