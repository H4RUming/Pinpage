import Foundation
import Testing
@testable import PinpageCore

/// 저장소의 실제 템플릿 폴더 (App/Resources/PromptTemplates).
let templateDirectory = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "App/Resources/PromptTemplates")

func realTemplates() throws -> PromptTemplates {
    try PromptTemplates { name in try? String(contentsOf: templateDirectory.appending(path: "\(name).md"), encoding: .utf8) }
}

@Suite("프롬프트 템플릿")
struct PromptTemplateTests {
    @Test("앱에 넣는 템플릿을 모두 읽고, 자리표시자가 남지 않게 채운다")
    func bundledTemplates() throws {
        let templates = try realTemplates()
        #expect(templates.hints.count == 3)
        let values = ["sources": "[1] a", "question": "q", "problem": "p", "level": "1"]
        for template in [templates.answerSystem, templates.answerUser, templates.hintSystem] + templates.hints {
            _ = try PromptTemplates.render(template, values)
        }
        #expect(try PromptTemplates.render(templates.hints[0], values).contains("힌트 1단계"))
    }

    @Test("채우지 못한 자리표시자와 빠진 파일을 알려준다")
    func errors() {
        #expect(throws: PromptTemplateError.unresolved("{{unknown}}")) {
            try PromptTemplates.render("질문: {{question}} {{unknown}}", ["question": "q"])
        }
        #expect(throws: PromptTemplateError.missing("hint-system")) {
            try PromptTemplates { ["answer-system": "a", "answer-user": "b"][$0] }
        }
        #expect(throws: PromptTemplateError.missing("hint-1")) {
            try PromptTemplates { ["answer-system": "a", "answer-user": "b", "hint-system": "c"][$0] }
        }
    }

    @Test("문구가 바뀌면 식별값도 바뀐다")
    func fingerprint() throws {
        let a = PromptTemplates(answerSystem: "a", answerUser: "b", hintSystem: "c", hints: ["d"])
        let b = PromptTemplates(answerSystem: "a", answerUser: "b", hintSystem: "c", hints: ["d!"])
        #expect(a.fingerprint == a.fingerprint)
        #expect(a.fingerprint != b.fingerprint)
        #expect(a.fingerprint.count == 16)
    }
}

@Suite("인용 검증과 강조 위치")
struct QuoteTests {
    let chunk = "교착 상태(데드락)는 둘 이상의 프로세스가 서로 상대가 가진 자원을 기다리며 영원히 멈춘 상태다. 상호 배제, 점유 대기, 비선점, 순환 대기 네 조건이 모두 성립할 때 생긴다."

    @Test("그대로 있거나 공백·문장부호만 다르면 인정한다")
    func accepts() {
        #expect(QuoteVerifier.verify(quote: "상호 배제, 점유 대기, 비선점, 순환 대기 네 조건이 모두 성립할 때 생긴다.", in: chunk))
        #expect(QuoteVerifier.verify(quote: "상호배제 점유대기 비선점 순환대기", in: chunk))
        #expect(QuoteVerifier.verify(quote: "교착 상태(데드락)는", in: chunk))
    }

    @Test("자료에 없는 인용, 너무 짧은 인용은 거부한다")
    func rejects() {
        #expect(!QuoteVerifier.verify(quote: "교착 상태는 운영체제가 자동으로 해결한다.", in: chunk))
        #expect(!QuoteVerifier.verify(quote: "", in: chunk))
        #expect(!QuoteVerifier.verify(quote: "상태", in: chunk))
    }

    @Test("끝 어미만 다른 인용은 인정하고, 중간에 말을 끼워 넣은 인용은 거부한다")
    func nearMatch() {
        #expect(QuoteVerifier.verify(quote: "상호 배제, 점유 대기, 비선점, 순환 대기 네 조건이 모두 성립할 때 생깁니다", in: chunk))
        #expect(!QuoteVerifier.verify(quote: "상호 배제, 점유 대기, 비선점, 순환 대기 네 가지 조건이 모두 성립할 때 생긴다.", in: chunk))
    }

    @Test("줄바꿈·단어 중간 줄바꿈이 있어도 페이지 텍스트에서 위치를 찾는다")
    func highlight() throws {
        let page = "제목\n교착 상태는 둘 이상의 프로세스가 서로 상대가 가진 자원을 기다리며 영원히 멈춘 상태다. 상\n호 배제, 점유 대기, 비선점,\n순환 대기 네 조건이 모두 성립할 때 생긴다."
        let range = try #require(HighlightLocator.range(of: "상호 배제, 점유 대기", in: page))
        #expect((page as NSString).substring(with: range) == "상\n호 배제, 점유 대기")
        // 범위를 주면 그 안에서만 찾는다.
        #expect(HighlightLocator.range(of: "상호 배제", in: page, within: NSRange(location: 0, length: 10)) == nil)
        #expect(HighlightLocator.range(of: "없는 문장입니다", in: page) == nil)
    }

    @Test("응답에서 JSON을 꺼낸다 (코드 블록, 앞뒤 문장)")
    func parse() {
        let fenced = "```json\n{\"status\": \"answered\", \"answer\": \"a\", \"citations\": [{\"source\": 1, \"quote\": \"q\"}]}\n```"
        #expect(ResponseParser.decode(RawGroundedResponse.self, from: fenced)?.citations?.first?.source == 1)
        #expect(ResponseParser.decode(RawGroundedResponse.self, from: "답: {\"status\":\"not_in_materials\"} 끝")?.status == "not_in_materials")
        #expect(ResponseParser.decode(RawGroundedResponse.self, from: "형식 없음") == nil)
    }

    @Test("근거 위치 문구")
    func label() {
        var chunk = Chunk(id: 1, documentId: "d", ordinal: 0, pageIndex: 11, paragraphStart: 1, paragraphEnd: 1,
                          charStart: 0, charEnd: 1, rects: [], source: .text, text: "x")
        #expect(CitationLabel.text(fileName: "강의자료.pdf", chunk: chunk) == "강의자료.pdf · 12쪽 · 2번째 문단")
        chunk.paragraphEnd = 2
        #expect(CitationLabel.paragraphs(chunk) == "2~3번째 문단")
    }
}

// MARK: - 답변 엔진 (가짜 LLM 서버)

/// 채팅 요청을 받아 정해 둔 응답을 돌려준다. 받은 요청 본문을 기록한다.
final class ChatServerStub: URLProtocol, @unchecked Sendable {
    struct Reply {
        let status: Int
        let body: Data

        static func content(_ text: String, finish: String = "stop", reasoning: String? = nil) -> Reply {
            var message: [String: Any] = ["role": "assistant", "content": text]
            if let reasoning { message["reasoning_content"] = reasoning }
            let body = try! JSONSerialization.data(withJSONObject: ["choices": [["message": message, "finish_reason": finish]]])
            return Reply(status: 200, body: body)
        }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [Reply] = []
    nonisolated(unsafe) private static var bodies: [[String: Any]] = []

    static func queue(_ replies: [Reply]) { lock.withLock { self.replies = replies; bodies = [] } }
    static var requests: [[String: Any]] { lock.withLock { bodies } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 65536); var collected = Data()
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; collected.append(buffer, count: n) }
            data = collected
        }
        let reply = Self.lock.withLock { () -> Reply in
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { Self.bodies.append(json) }
            return Self.replies.isEmpty ? Reply(status: 500, body: Data()) : Self.replies.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// 가짜 LLM 서버(ChatServerStub)를 쓰는 테스트 묶음. 핸들러가 전역 하나라 순서대로 돌린다.
@Suite(.serialized) enum ChatStubbed {}

extension ChatStubbed {
@Suite("답변과 힌트")
struct AnswerEngineTests {
    private func makeEngine(enforceSchema: Bool = true, emptySet: Bool = false) async throws -> (AnswerEngine, String) {
        let library = Library(database: try AppDatabase.inMemory(),
                              filesRoot: FileManager.default.temporaryDirectory.appending(path: "pinpage-ans-\(UUID().uuidString)"))
        let set = try library.createSet(name: "운영체제")
        if !emptySet {
            let pdf = try TestPDF.make(pages: [
                ["교착 상태(데드락)는 둘 이상의 프로세스가 서로 상대가 가진 자원을 기다리며 영원히 멈춘 상태다. 상호 배제, 점유 대기, 비선점, 순환 대기 네 조건이 모두 성립할 때 교착 상태가 생긴다."],
                ["경쟁 상태는 여러 스레드가 공유 데이터에 동시에 접근할 때 실행 순서에 따라 결과가 달라지는 문제다."],
            ])
            let document = try library.importPDF(from: pdf, into: set.id)
            try await DocumentIndexer(library: library).index(
                documentId: document.id,
                options: IndexingOptions(chunkSize: 800, chunkOverlap: 100, minChunkLength: 0, ocrLanguages: [], prompts: nil),
                embedder: nil)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatServerStub.self]
        let client = OpenAIClient(endpoint: try APIEndpoint(baseURL: "gpu-server:8000"), timeoutSeconds: 10,
                                  retryPolicy: RetryPolicy(maxRetries: 0), session: URLSession(configuration: configuration))
        let engine = AnswerEngine(
            search: SearchService(database: library.database), client: client, templates: try realTemplates(),
            configuration: .init(model: "qwen", temperature: 0, maxTokens: 512, enforceJSONSchema: enforceSchema,
                                 extraBody: ["chat_template_kwargs": ["enable_thinking": false]], topK: 3, embeddingWeight: 0.5),
            embedder: nil, embeddingPrompts: nil)
        return (engine, set.id)
    }

    private func json(_ object: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    @Test("근거가 확인된 답변: 요청에 자료·질문·추가 파라미터·스키마가 들어간다")
    func answered() async throws {
        let (engine, setId) = try await makeEngine()
        ChatServerStub.queue([.content(json([
            "status": "answered", "answer": "네 조건이 모두 성립할 때 생깁니다.",
            "citations": [["source": 1, "quote": "상호 배제, 점유 대기, 비선점, 순환 대기 네 조건이 모두 성립할 때"]],
        ]), reasoning: "생각")])
        let result = try await engine.answer(question: "데드락이 생기는 조건은?", problem: nil, setId: setId)
        #expect(result.status == .answered)
        #expect(result.text == "네 조건이 모두 성립할 때 생깁니다.")
        let citation = try #require(result.citations.first)
        #expect(result.citations.count == 1)
        #expect(citation.hit.chunk.pageIndex == 0)
        #expect(citation.label.contains("1쪽"))
        #expect(result.reasoning == "생각")
        #expect(result.usedJSONSchema)
        #expect(result.templateFingerprint == (try realTemplates()).fingerprint)

        let request = try #require(ChatServerStub.requests.first)
        #expect(request["model"] as? String == "qwen")
        #expect(request["max_tokens"] as? Int == 512)
        #expect((request["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == false)
        #expect((request["response_format"] as? [String: Any])?["type"] as? String == "json_schema")
        let messages = try #require(request["messages"] as? [[String: String]])
        #expect(messages.map { $0["role"] } == ["system", "user"])
        #expect(messages[1]["content"]?.contains("[1] ") == true)
        #expect(messages[1]["content"]?.contains("데드락이 생기는 조건은?") == true)
        #expect(messages[1]["content"]?.contains("{{") == false)
    }

    @Test("자료에 없는 인용과 없는 근거 번호는 버리고, 남는 근거가 없으면 '자료에 없음'")
    func strictGrounding() async throws {
        let (engine, setId) = try await makeEngine()
        ChatServerStub.queue([.content(json([
            "status": "answered", "answer": "운영체제가 자동으로 풀어 줍니다.",
            "citations": [["source": 1, "quote": "운영체제가 자동으로 해결한다"], ["source": 7, "quote": "교착 상태"]],
        ]))])
        let result = try await engine.answer(question: "데드락은 어떻게 풀려?", problem: nil, setId: setId)
        #expect(result.status == .notInMaterials)
        #expect(result.notInMaterialsReason == "근거 확인 실패")
        #expect(result.text.isEmpty)
        #expect(result.dropped.map(\.reason) == ["인용이 자료에 없음", "없는 근거 번호"])
        #expect(result.rawResponse?.contains("자동으로") == true)  // 원래 응답은 로그용으로 남는다
    }

    @Test("모델이 '자료에 없음'이라고 하면 그대로 따른다")
    func modelSaysAbsent() async throws {
        let (engine, setId) = try await makeEngine()
        ChatServerStub.queue([.content(json(["status": "not_in_materials", "answer": "", "citations": []]))])
        let result = try await engine.answer(question: "TCP 핸드셰이크는?", problem: nil, setId: setId)
        #expect(result.status == .notInMaterials)
        #expect(result.notInMaterialsReason == "모델 판단")
    }

    @Test("자료가 없으면 LLM에 묻지 않는다")
    func emptySet() async throws {
        let (engine, setId) = try await makeEngine(emptySet: true)
        ChatServerStub.queue([])
        let result = try await engine.answer(question: "아무거나", problem: nil, setId: setId)
        #expect(result.status == .notInMaterials)
        #expect(result.notInMaterialsReason == "검색된 자료 없음")
        #expect(ChatServerStub.requests.isEmpty)
    }

    @Test("서버가 JSON 스키마를 거부하면 한 번만 스키마 없이 다시 보낸다")
    func schemaFallback() async throws {
        let (engine, setId) = try await makeEngine()
        ChatServerStub.queue([
            .init(status: 400, body: Data(#"{"message": "response_format json_schema is not supported"}"#.utf8)),
            .content("```json\n" + json(["status": "answered", "answer": "a", "citations": [["source": 1, "quote": "둘 이상의 프로세스가 서로"]]]) + "\n```"),
        ])
        let result = try await engine.answer(question: "교착 상태란?", problem: nil, setId: setId)
        #expect(result.status == .answered)
        #expect(!result.usedJSONSchema)
        #expect(ChatServerStub.requests.count == 2)
        #expect(ChatServerStub.requests[0]["response_format"] != nil)
        #expect(ChatServerStub.requests[1]["response_format"] == nil)
    }

    @Test("스키마 강제를 끄면 처음부터 스키마 없이 보낸다")
    func schemaOff() async throws {
        let (engine, setId) = try await makeEngine(enforceSchema: false)
        ChatServerStub.queue([.content(json(["status": "not_in_materials", "answer": "", "citations": []]))])
        _ = try await engine.answer(question: "q", problem: nil, setId: setId)
        #expect(ChatServerStub.requests.first?["response_format"] == nil)
    }

    @Test("1단계 힌트는 위치만: 모델 문장 없이 근거 번호만 쓴다")
    func hintLevel1() async throws {
        let (engine, setId) = try await makeEngine()
        ChatServerStub.queue([.content(json(["status": "answered", "sources": [2, 2, 9]]))])
        let result = try await engine.hint(level: 1, problem: "교착 상태가 생기는 조건을 쓰시오.", question: nil, setId: setId)
        #expect(result.kind == .hint(level: 1))
        #expect(result.status == .answered)
        #expect(result.text.isEmpty)
        #expect(result.citations.map(\.source) == [2])
        #expect(result.citations.allSatisfy { $0.quote.isEmpty })
        #expect(result.dropped.map(\.source) == [9])
        let request = try #require(ChatServerStub.requests.first)
        let schema = (request["response_format"] as? [String: Any])?["json_schema"] as? [String: Any]
        #expect(((schema?["schema"] as? [String: Any])?["required"] as? [String]) == ["status", "sources"])
        let messages = request["messages"] as? [[String: String]]
        #expect(messages?[1]["content"]?.contains("힌트 1단계") == true)
        #expect(messages?[1]["content"]?.contains("교착 상태가 생기는 조건을 쓰시오.") == true)
    }

    @Test("2·3단계 힌트는 설명과 근거를 검증한다")
    func hintLevel3() async throws {
        let (engine, setId) = try await makeEngine()
        ChatServerStub.queue([.content(json([
            "status": "answered", "answer": "정답: 상호 배제, 점유 대기, 비선점, 순환 대기",
            "citations": [["source": 1, "quote": "상호 배제, 점유 대기, 비선점, 순환 대기 네 조건이 모두 성립할 때"]],
        ]))])
        let result = try await engine.hint(level: 3, problem: "교착 상태가 생기는 조건을 쓰시오.", question: nil, setId: setId)
        #expect(result.status == .answered)
        #expect(result.text.hasPrefix("정답"))
        #expect(result.citations.count == 1)
        #expect((ChatServerStub.requests.first?["messages"] as? [[String: String]])?[1]["content"]?.contains("힌트 3단계") == true)
    }

    @Test("최대 길이에서 잘린 답과 해석할 수 없는 답은 오류로 알린다")
    func failures() async throws {
        let (engine, setId) = try await makeEngine()
        ChatServerStub.queue([.content("{\"status\": \"answ", finish: "length")])
        await #expect(throws: AnswerEngineError.self) { try await engine.answer(question: "교착", problem: nil, setId: setId) }
        ChatServerStub.queue([.content("그냥 문장으로 답했습니다.")])
        await #expect(throws: AnswerEngineError.self) { try await engine.answer(question: "교착", problem: nil, setId: setId) }
    }
}

}

@Suite("생성 설정")
struct GenerationSettingsTests {
    @Test("추가 요청 파라미터는 JSON 객체여야 한다")
    func extraBody() {
        var s = AppSettings()
        #expect(s.generation.extraBody?.isEmpty == true)
        s.generation.extraBodyJSON = #"{"chat_template_kwargs": {"enable_thinking": false}}"#
        #expect((s.generation.extraBody?["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == false)
        #expect(s.validate().isEmpty)
        s.generation.extraBodyJSON = "[1, 2]"
        #expect(s.validate().map(\.field) == ["추가 요청 파라미터"])
        s.generation.extraBodyJSON = "{broken"
        #expect(s.validate().map(\.field) == ["추가 요청 파라미터"])
    }

    @Test("설정 파일 왕복")
    func roundTrip() throws {
        var s = AppSettings()
        s.generation.temperature = 0.3
        s.generation.maxTokens = 2048
        s.generation.enforceJSONSchema = false
        s.generation.extraBodyJSON = #"{"top_p": 0.9}"#
        let data = try SettingsTransfer.exportData(s, appVersion: "0.1.0")
        #expect(try SettingsTransfer.importSettings(from: data, keepingSecretsFrom: s) == s)
    }
}
