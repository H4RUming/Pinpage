import PinpageCore
import SwiftUI

/// Chat API 또는 임베딩 API의 주소, 키, 모델 선택, 연결 테스트.
struct EndpointSection: View {
    @Environment(AppModel.self) private var model
    let role: EndpointRole

    var body: some View {
        @Bindable var model = model
        let state = model.state(for: role)
        let locked = model.isSettingsLocked

        Section {
            if role == .embedding {
                Toggle("Chat API와 같은 서버 사용", isOn: $model.settings.embedding.useChatServer)
                    .disabled(locked)
            }
            if showsServerFields {
                TextField("주소", text: baseURL, prompt: Text("예: http://gpu-server:8000"))
                    .disabled(locked)
                AddressInfo(raw: baseURL.wrappedValue)
                SecureField("API 키 (선택)", text: apiKey, prompt: Text("키가 필요 없는 서버는 비워두세요"))
                    .disabled(locked)
            }
            ModelPickerRow(role: role, state: state, selection: modelName)
                .disabled(locked)
            ConnectionTestRow(role: role, state: state, canTest: !modelName.wrappedValue.isEmpty)
        } header: {
            Text(role.title)
        } footer: {
            switch role {
            case .chat:
                Text("API 키는 이 Mac에만 저장되며 설정 내보내기 파일에는 포함되지 않습니다. 로컬·Tailscale 서버처럼 키가 필요 없으면 비워두세요.")
            case .embedding:
                Text("OpenAI 호환 /v1/embeddings를 제공하는 서버여야 합니다.")
            }
        }
        .onChange(of: baseURL.wrappedValue) { model.serverInputChanged(role) }
        .onChange(of: apiKey.wrappedValue) { model.serverInputChanged(role) }
        .onChange(of: model.settings.embedding.useChatServer) {
            if role == .embedding { model.serverInputChanged(.embedding) }
        }
        .task {
            if state.models.isEmpty && state.modelsError == nil {
                await model.loadModels(role)
            }
        }
    }

    private var showsServerFields: Bool {
        role == .chat || !model.settings.embedding.useChatServer
    }

    private var baseURL: Binding<String> {
        @Bindable var model = model
        return role == .chat ? $model.settings.chat.baseURL : $model.settings.embedding.baseURL
    }

    private var apiKey: Binding<String> {
        @Bindable var model = model
        return role == .chat ? $model.settings.chat.apiKey : $model.settings.embedding.apiKey
    }

    private var modelName: Binding<String> {
        @Bindable var model = model
        return role == .chat ? $model.settings.chat.model : $model.settings.embedding.model
    }
}

/// 정규화한 요청 주소와 주소 종류, 또는 입력 오류를 보여준다.
private struct AddressInfo: View {
    let raw: String

    var body: some View {
        if raw.trimmingCharacters(in: .whitespaces).isEmpty {
            EmptyView()
        } else {
            switch Result(catching: { () throws(EndpointError) in try APIEndpoint(baseURL: raw) }) {
            case .success(let endpoint):
                Text("요청 주소: \(endpoint.baseURL.absoluteString) · \(endpoint.hostKind.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            case .failure(let error):
                Text(error.message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct ModelPickerRow: View {
    @Environment(AppModel.self) private var model
    let role: EndpointRole
    let state: EndpointState
    @Binding var selection: String

    var body: some View {
        let missing = !selection.isEmpty && state.modelsLoadedFrom != nil && !state.models.contains(selection)

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("모델", selection: $selection) {
                    Text("선택하세요").tag("")
                    ForEach(state.models, id: \.self) { name in
                        Text(name).tag(name)
                    }
                    if !selection.isEmpty && !state.models.contains(selection) {
                        Text("\(selection) (서버 목록에 없음)").tag(selection)
                    }
                }
                Button {
                    Task { await model.loadModels(role) }
                } label: {
                    if state.isLoadingModels {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("모델 불러오기")
                    }
                }
                .disabled(state.isLoadingModels)
            }
            if let error = state.modelsError {
                Label(error, systemImage: "xmark.octagon.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else if missing {
                Label("선택한 모델 '\(selection)'이(가) 서버 목록에 없습니다. 다른 모델을 고르세요.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else if !state.models.isEmpty {
                Text("모델 \(state.models.count)개를 불러왔습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ConnectionTestRow: View {
    @Environment(AppModel.self) private var model
    let role: EndpointRole
    let state: EndpointState
    let canTest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("연결 테스트") {
                    Task { await model.testConnection(role) }
                }
                .disabled(!canTest || state.isTesting)
                if state.isTesting {
                    ProgressView().controlSize(.small)
                    Text("응답을 기다리는 중…").foregroundStyle(.secondary)
                }
            }
            switch state.testResult {
            case .success(let text):
                Label(text, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failure(let text):
                Label(text, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            case nil:
                EmptyView()
            }
        }
    }
}
