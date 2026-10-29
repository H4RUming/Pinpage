import PinpageCore
import SwiftUI

/// 학습 화면: 왼쪽에 문제·질문·답변·힌트, 오른쪽에 근거 PDF.
struct StudyView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let library = app.libraryModel {
            HStack(spacing: 0) {
                StudyPanel(study: app.studyModel, library: library)
                    .frame(width: 430)
                Divider()
                PDFViewerPane(target: app.studyModel.viewerTarget)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("학습")
        } else {
            ContentUnavailableView("자료 DB를 열 수 없습니다", systemImage: "exclamationmark.triangle")
        }
    }
}

private struct StudyPanel: View {
    @Bindable var study: StudyModel
    @Bindable var library: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("학습 세트", selection: $library.selectedSetId) {
                    ForEach(library.sets) { set in Text(set.name).tag(Optional(set.id)) }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button("기록 지우기") { study.clear() }
                    .disabled(study.entries.isEmpty || study.isBusy)
            }

            if let reason = study.unavailableReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            ProblemBox(study: study)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(study.entries) { entry in
                            EntryCard(entry: entry, study: study).id(entry.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: study.entries.count) {
                    if let last = study.entries.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                .overlay {
                    if study.entries.isEmpty {
                        ContentUnavailableView("자료에 대해 질문하세요", systemImage: "questionmark.bubble",
                                               description: Text("답에는 근거 위치가 붙습니다. 자료에 없는 내용은 '자료에 없음'으로 답합니다."))
                    }
                }
            }

            HStack(alignment: .bottom) {
                TextField("질문을 입력하세요", text: $study.question, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit { study.ask() }
                Button("질문") { study.ask() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(study.question.trimmingCharacters(in: .whitespaces).isEmpty || study.isBusy)
            }
        }
        .padding(16)
    }
}

/// 현재 연습 문제와 단계별 힌트 버튼.
private struct ProblemBox: View {
    @Bindable var study: StudyModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("연습 문제").font(.headline)
            TextField("풀고 있는 문제를 입력하세요 (연습 문제 자동 제시는 다음 단계에서 붙습니다)",
                      text: $study.problem, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            HStack {
                if study.nextHintLevel <= study.hintLevelCount {
                    Button("힌트 \(study.nextHintLevel)단계 보기") { study.requestHint() }
                        .disabled(study.problem.trimmingCharacters(in: .whitespaces).isEmpty || study.isBusy)
                    Text(hintDescription(study.nextHintLevel)).font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("모든 힌트를 봤습니다", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if study.isBusy { ProgressView().controlSize(.small) }
            }
        }
    }

    private func hintDescription(_ level: Int) -> String {
        switch level {
        case 1: "읽어야 할 위치"
        case 2: "해당 부분 설명"
        default: "정답과 풀이"
        }
    }
}

private struct EntryCard: View {
    let entry: StudyModel.Entry
    let study: StudyModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch entry.kind {
            case .question(let text):
                Label(text, systemImage: "person.fill").font(.callout.bold())
            case .hint(let level):
                Label("힌트 \(level)단계", systemImage: "lightbulb.fill").font(.callout.bold()).foregroundStyle(.orange)
            }

            if let error = entry.error {
                Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red).textSelection(.enabled)
            } else if let result = entry.result {
                body(for: result)
            } else {
                HStack { ProgressView().controlSize(.small); Text("자료를 찾아 답하는 중…").foregroundStyle(.secondary) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func body(for result: GroundedResult) -> some View {
        switch result.status {
        case .notInMaterials:
            Label("자료에 없음", systemImage: "questionmark.folder").font(.body.bold())
            Text(notInMaterialsDetail(result)).font(.caption).foregroundStyle(.secondary)
        case .answered:
            if result.kind == .hint(level: 1) {
                Text("다음 위치를 읽어 보세요.")
            } else if !result.text.isEmpty {
                Text(result.text).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(StudyModel.grouped(result.citations), id: \.first!.source) { group in
                    let first = group[0]
                    Button {
                        study.show(group)
                    } label: {
                        Label(first.label, systemImage: first.hit.chunk.source == .ocr ? "doc.viewfinder" : "doc.text")
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.link)
                    .help(group.allSatisfy { $0.quote.isEmpty }
                          ? first.hit.chunk.text
                          : group.map { "“\($0.quote)”" }.joined(separator: "\n"))
                }
            }
        }
        Text(footer(result)).font(.caption2).foregroundStyle(.tertiary)
    }

    private func notInMaterialsDetail(_ result: GroundedResult) -> String {
        switch result.notInMaterialsReason {
        case "근거 확인 실패": "모델이 답했지만 자료에서 근거를 확인할 수 없어 보여주지 않습니다."
        case "검색된 자료 없음": "이 세트에 색인된 자료가 없습니다."
        default: "학습 자료에서 이 내용을 찾지 못했습니다."
        }
    }

    private func footer(_ result: GroundedResult) -> String {
        var parts = ["검색 \(result.hits.count)개", result.usedEmbedding ? "하이브리드" : "키워드 검색"]
        if result.latencyMs > 0 { parts.append(String(format: "응답 %.1f초", Double(result.latencyMs) / 1000)) }
        return parts.joined(separator: " · ")
    }
}
