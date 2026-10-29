import AppKit
import PinpageCore
import SwiftUI
import UniformTypeIdentifiers

/// 학습 세트 화면. 위쪽 메뉴에서 세트를 고르고, 아래에서 자료 목록·색인·검색 테스트를 본다.
struct LearningSetsView: View {
    @Environment(AppModel.self) private var app
    @State private var naming: NamingRequest?
    @State private var deleting: LearningSet?

    struct NamingRequest: Identifiable {
        let id = UUID()
        let setId: String?
        var name: String
    }

    var body: some View {
        if let library = app.libraryModel {
            Group {
                if let set = library.selectedSet {
                    SetDetailView(library: library, set: set, naming: $naming, deleting: $deleting)
                } else {
                    ContentUnavailableView {
                        Label("학습 세트가 없습니다", systemImage: "folder.badge.plus")
                    } description: {
                        Text("세트를 만들고 PDF를 넣으세요. 세트 하나에 PDF 여러 개를 넣을 수 있습니다.")
                    } actions: {
                        Button("새 학습 세트 만들기") { naming = NamingRequest(setId: nil, name: "") }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("학습 세트")
            .alert(naming?.setId == nil ? "새 학습 세트" : "이름 바꾸기",
                   isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
                TextField("이름", text: Binding(get: { naming?.name ?? "" }, set: { naming?.name = $0 }))
                Button("확인") {
                    guard let request = naming else { return }
                    if let id = request.setId {
                        library.renameSet(id: id, to: request.name)
                    } else {
                        library.createSet(name: request.name)
                    }
                }
                Button("취소", role: .cancel) {}
            }
            .confirmationDialog("'\(deleting?.name ?? "")' 세트를 삭제할까요?",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("삭제", role: .destructive) {
                    if let set = deleting { library.deleteSet(id: set.id) }
                }
            } message: {
                Text("세트 안의 자료와 색인이 모두 지워집니다. 되돌릴 수 없습니다.")
            }
            .alert("알림", isPresented: Binding(get: { library.errorMessage != nil },
                                              set: { if !$0 { library.errorMessage = nil } })) {
                Button("확인") {}
            } message: {
                Text(library.errorMessage ?? "")
            }
        } else {
            ContentUnavailableView("자료 DB를 열 수 없습니다", systemImage: "exclamationmark.triangle",
                                   description: Text(app.banner ?? ""))
        }
    }
}

private struct SetDetailView: View {
    @Bindable var library: LibraryModel
    let set: LearningSet
    @Binding var naming: LearningSetsView.NamingRequest?
    @Binding var deleting: LearningSet?
    @State private var isDropTarget = false

    var body: some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 12) {
                header
                banners
                DocumentTable(library: library)
                    .overlay {
                        if library.documents.isEmpty {
                            ContentUnavailableView("PDF를 끌어다 놓거나 [PDF 추가…]를 누르세요", systemImage: "doc.badge.plus")
                        }
                    }
                    .overlay {
                        if isDropTarget { RoundedRectangle(cornerRadius: 8).stroke(.tint, lineWidth: 3) }
                    }
                    .dropDestination(for: URL.self) { urls, _ in
                        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
                        guard !pdfs.isEmpty else { return false }
                        library.addPDFs(pdfs)
                        return true
                    } isTargeted: { isDropTarget = $0 }
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 260, maxHeight: .infinity, alignment: .topLeading)

            SearchTestView(library: library)
                .padding(20)
                .frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Picker("학습 세트", selection: $library.selectedSetId) {
                ForEach(library.sets) { set in
                    Text(set.name).tag(Optional(set.id))
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(library.indexing != nil)

            Menu {
                Button("새 학습 세트…") { naming = .init(setId: nil, name: "") }
                Button("이름 바꾸기…") { naming = .init(setId: set.id, name: set.name) }
                Divider()
                Button("세트 삭제…", role: .destructive) { deleting = set }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("학습 세트 관리")
            .disabled(library.indexing != nil)

            Spacer()

            Button {
                choosePDFs()
            } label: {
                Label("PDF 추가…", systemImage: "plus")
            }
            .disabled(library.indexing != nil)
        }
    }

    @ViewBuilder private var banners: some View {
        if let state = library.indexing {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("색인 중: \(state.fileName) · \(state.detail)")
                    if state.remaining > 0 { Text("(대기 \(state.remaining)개)").foregroundStyle(.secondary) }
                    Spacer()
                    Button("중지") { library.cancelIndexing() }
                }
                ProgressView(value: state.fraction)
            }
        } else if let reason = library.indexingBlockedReason, !library.documents.isEmpty {
            Label(reason, systemImage: "hourglass").foregroundStyle(.orange)
        } else if !library.outdatedDocuments.isEmpty {
            HStack {
                Label("현재 설정으로 색인되지 않은 자료가 \(library.outdatedDocuments.count)개 있습니다.",
                      systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
                Spacer()
                Button("색인하기") { library.reindexOutdated() }
            }
        }
    }

    private func choosePDFs() {
        let panel = NSOpenPanel()
        panel.title = "PDF 추가"
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        library.addPDFs(panel.urls)
    }
}

private struct DocumentTable: View {
    @Bindable var library: LibraryModel
    @State private var selection: String?

    var body: some View {
        Table(library.documents, selection: $selection) {
            TableColumn("파일") { row in
                Text(row.document.fileName).help(row.document.fileName)
            }
            TableColumn("쪽") { row in
                Text("\(row.document.pageCount)").monospacedDigit()
            }
            .width(40)
            TableColumn("OCR 쪽") { row in
                Text(row.document.ocrPageCount > 0 ? "\(row.document.ocrPageCount)" : "–").monospacedDigit()
            }
            .width(55)
            TableColumn("청크") { row in
                Text("\(row.chunkCount)").monospacedDigit()
            }
            .width(50)
            TableColumn("상태") { row in
                status(row.document)
            }
            .width(min: 120)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first {
                Button("다시 색인") { library.reindex(id) }
                Button("삭제", role: .destructive) { library.deleteDocument(id) }
            }
        }
    }

    @ViewBuilder private func status(_ document: PinpageCore.Document) -> some View {
        switch document.status {
        case .pending:
            Text("색인 대기").foregroundStyle(.secondary)
        case .indexing:
            Text("색인 중…").foregroundStyle(.secondary)
        case .failed:
            Label(document.errorMessage ?? "실패", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red).help(document.errorMessage ?? "")
        case .indexed:
            if library.isUpToDate(document) {
                Label("색인됨", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Label("다시 색인 필요", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
            }
        }
    }
}

/// 질문을 넣어 어떤 청크와 페이지가 나오는지 확인한다 (M2 완료 기준 확인용).
private struct SearchTestView: View {
    @Bindable var library: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("검색 테스트").font(.headline)
            HStack {
                TextField("질문을 입력하세요", text: $library.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { library.runSearch() }
                Button("검색") { library.runSearch() }
                    .disabled(library.query.trimmingCharacters(in: .whitespaces).isEmpty || library.isSearching)
                if library.isSearching { ProgressView().controlSize(.small) }
            }
            if let error = library.searchError {
                Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
            if let result = library.searchResult {
                Text(result.usedEmbedding ? "하이브리드 검색 (BM25 + 임베딩)" : (result.embeddingUnavailableReason ?? "키워드 검색(BM25)만 사용"))
                    .font(.caption)
                    .foregroundStyle(result.usedEmbedding ? Color.secondary : Color.orange)
                if result.hits.isEmpty {
                    Text("결과가 없습니다.").foregroundStyle(.secondary)
                }
                List(result.hits) { hit in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("#\(hit.rank)").bold().monospacedDigit()
                            Text(location(hit)).bold()
                            if hit.chunk.source == .ocr { Text("OCR").font(.caption2).padding(.horizontal, 4).background(.quaternary, in: Capsule()) }
                            Spacer()
                            Text(scores(hit)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Text(hit.chunk.text)
                            .lineLimit(4)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
    }

    private func location(_ hit: SearchHit) -> String {
        let c = hit.chunk
        let paragraphs = c.paragraphStart == c.paragraphEnd
            ? "\(c.paragraphStart + 1)번째 문단"
            : "\(c.paragraphStart + 1)~\(c.paragraphEnd + 1)번째 문단"
        return "\(hit.document.fileName) · \(c.pageIndex + 1)쪽 · \(paragraphs)"
    }

    private func scores(_ hit: SearchHit) -> String {
        var text = String(format: "점수 %.2f · BM25 %.2f", hit.score, hit.bm25)
        if let semantic = hit.semantic { text += String(format: " · 임베딩 %.3f", semantic) }
        return text
    }
}
