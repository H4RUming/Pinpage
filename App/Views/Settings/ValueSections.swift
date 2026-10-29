import PinpageCore
import SwiftUI

/// 네트워크, 검색, 학습 관련 수치 설정.
struct ValueSections: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Group {
            Section("네트워크") {
                IntField(title: "연결 테스트 시간 제한", value: $model.settings.network.testTimeoutSeconds,
                         range: SettingsLimits.testTimeoutSeconds, unit: "초")
                IntField(title: "답변 생성 시간 제한", value: $model.settings.network.requestTimeoutSeconds,
                         range: SettingsLimits.requestTimeoutSeconds, step: 10, unit: "초")
                IntField(title: "실패 시 최대 재시도", value: $model.settings.network.maxRetries,
                         range: SettingsLimits.maxRetries, unit: "회")
            }

            Section {
                IntField(title: "청크 크기", value: $model.settings.retrieval.chunkSize,
                         range: SettingsLimits.chunkSize, step: 100, unit: "글자")
                IntField(title: "청크 겹침", value: $model.settings.retrieval.chunkOverlap,
                         range: SettingsLimits.chunkOverlap, step: 50, unit: "글자")
                IntField(title: "짧은 문단 합치기 기준", value: $model.settings.retrieval.minChunkLength,
                         range: SettingsLimits.minChunkLength, step: 10, unit: "글자")
                IntField(title: "검색 결과 개수", value: $model.settings.retrieval.topK,
                         range: SettingsLimits.topK, unit: "개")
                LabeledContent("임베딩 검색 비중") {
                    HStack {
                        Slider(value: $model.settings.retrieval.embeddingWeight, in: SettingsLimits.embeddingWeight, step: 0.1)
                            .frame(width: 180)
                        Text(model.settings.retrieval.embeddingWeight, format: .number.precision(.fractionLength(1)))
                            .monospacedDigit()
                            .frame(width: 32, alignment: .trailing)
                    }
                }
            } header: {
                Text("검색")
            } footer: {
                Text("문단 하나가 청크 하나가 됩니다. 청크 크기보다 긴 문단은 겹침만큼 겹치게 자르고, 합치기 기준보다 짧은 문단(제목 등)은 다음 문단과 합칩니다. 임베딩 검색 비중이 0이면 키워드 검색(BM25)만, 1이면 임베딩 검색만 사용합니다. 이 값들이 바뀌면 학습 세트를 다시 색인해야 합니다.")
            }

            Section("학습") {
                IntField(title: "퀴즈 통과 기준", value: passThresholdPercent, range: 0...100, step: 5, unit: "%")
                IntField(title: "힌트 단계 수", value: $model.settings.learning.hintLevels,
                         range: SettingsLimits.hintLevels, unit: "단계")
            }
        }
        .disabled(model.isSettingsLocked)
    }

    private var passThresholdPercent: Binding<Int> {
        @Bindable var model = model
        return Binding(
            get: { Int((model.settings.learning.quizPassThreshold * 100).rounded()) },
            set: { model.settings.learning.quizPassThreshold = Double($0) / 100 }
        )
    }
}

/// 숫자 입력칸과 스테퍼. 범위를 벗어난 값은 범위 안으로 맞춘다.
private struct IntField: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    let unit: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, value: clamped, format: .number.grouping(.never))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                Text(unit)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 28, alignment: .leading)
                Stepper(title, value: $value, in: range, step: step)
                    .labelsHidden()
            }
        }
    }

    private var clamped: Binding<Int> {
        Binding(
            get: { value },
            set: { value = min(max($0, range.lowerBound), range.upperBound) }
        )
    }
}
