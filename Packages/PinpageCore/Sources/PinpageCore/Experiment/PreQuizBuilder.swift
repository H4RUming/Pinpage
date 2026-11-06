import Foundation
import GRDB

/// 사전 퀴즈 문제 후보 (진행자가 검토해 고른다).
public struct PreQuizDraft: Identifiable, Sendable {
    public var id: String { question.id }
    public let question: QuizQuestion
    /// 근거 위치 (예: "강의자료.pdf · 3쪽 · 2번째 문단")
    public let sourceLabel: String
    public let difficulty: Int
    /// 정답의 근거 인용
    public let quotes: [String]
}

/// 진행자 Mac에서 학습 세트로 사전 퀴즈를 만든다.
///
/// 참가자 앱에서 매번 만들지 않는 이유: 같은 요청을 temperature 0, 같은 seed로 보내도 서버가 여러 요청을 함께
/// 처리하면 결과가 달라진다. 그래서 한 번 만들어 진행자가 검토한 뒤 퀴즈 파일로 고정해 나눠 준다.
///
/// - 출제 위치: 세트의 모든 청크(문서 순서)에서 고르게 떨어진 위치를 고른다. 실패하면 바로 다음 청크로 다시 시도한다.
/// - 유형은 고른 유형을 번갈아, 난이도는 1·2·3을 번갈아 낸다 (점수가 학습자 수준을 고르게 가르도록).
/// - 객관식은 연습 문제처럼 같은 모델이 자료만 보고 풀어 정답 번호를 검증한다.
/// - 템플릿 자리표시자는 연습 문제와 같다: `{{sources}}`, `{{type}}`, `{{difficulty}}`, `{{avoid}}`
public struct PreQuizBuilder: Sendable {
    public static let triesPerQuestion = 3

    public let generator: ProblemGenerator

    /// `request`의 temperature는 0으로 바꿔서 쓴다.
    public init(database: AppDatabase, client: OpenAIClient, templates: PromptTemplates, request: StructuredRequest) {
        var fixed = request
        fixed.temperature = 0
        generator = ProblemGenerator(database: database, client: client, templates: templates, request: fixed)
    }

    public struct Output: Sendable {
        public let drafts: [PreQuizDraft]
        public let failures: [ProblemGenerationFailure]
    }

    /// - Parameter progress: (끝낸 문제 수, 전체) — 문제를 하나 끝낼 때마다 부른다.
    public func build(setId: String, count: Int, types: [QuizQuestionType],
                      progress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> Output {
        let types = types.isEmpty ? QuizQuestionType.allCases : types
        let (chunks, documents) = try candidates(setId: setId)
        guard !chunks.isEmpty, count > 0 else { throw ProblemGenerationError.noMaterials }
        let total = min(count, chunks.count)
        let slots = Self.spreadIndices(count: total, in: chunks.count)

        var drafts: [PreQuizDraft] = []
        var failures: [ProblemGenerationFailure] = []
        var used = Set<Int>()
        for (number, start) in slots.enumerated() {
            let type = types[number % types.count]
            let difficulty = number % 3 + 1
            var index = start
            for _ in 0..<Self.triesPerQuestion {
                while used.contains(index) && index < chunks.count - 1 { index += 1 }
                guard index < chunks.count, !used.contains(index) else { break }
                used.insert(index)
                let chunk = chunks[index]
                let neighbor = index + 1 < chunks.count && chunks[index + 1].documentId == chunk.documentId ? chunks[index + 1] : nil
                let target = ProblemGenerator.Target(chunk: chunk, neighbor: neighbor, documents: documents,
                                                     previousQuestions: drafts.map(\.question.prompt))
                do {
                    let problem = try await generator.makeProblem(
                        setId: setId, target: target, type: type.problemType, difficulty: difficulty,
                        system: generator.templates.prequizSystem, user: generator.templates.prequizUser)
                    let fileName = documents[chunk.documentId]?.fileName ?? ""
                    drafts.append(PreQuizDraft(
                        question: Self.question(from: problem, id: "pre-\(drafts.count + 1)",
                                                source: CitationLabel.text(fileName: fileName, chunk: chunk)),
                        sourceLabel: CitationLabel.text(fileName: fileName, chunk: chunk),
                        difficulty: difficulty, quotes: problem.keyPoints.map(\.quote)))
                    break
                } catch let failure as ProblemGenerator.Failure {
                    failures.append(ProblemGenerationFailure(chunkId: chunk.id ?? -1, type: type.rawValue,
                                                             reason: failure.reason, rawResponse: failure.raw))
                    index += 1
                }
            }
            await progress(number + 1, total)
        }
        guard !drafts.isEmpty else { throw ProblemGenerationError.noValidProblem(failures: failures) }
        return Output(drafts: drafts, failures: failures)
    }

    /// `n`개 중 고르게 떨어진 `count`개의 위치 (각 구간의 가운데).
    static func spreadIndices(count: Int, in n: Int) -> [Int] {
        guard count > 0, n > 0 else { return [] }
        return (0..<min(count, n)).map { i in min(n - 1, Int((Double(i) + 0.5) * Double(n) / Double(min(count, n)))) }
    }

    static func question(from problem: PracticeProblem, id: String, source: String) -> QuizQuestion {
        switch problem.type {
        case .multipleChoice:
            QuizQuestion(id: id, type: .multipleChoice, prompt: problem.question, choices: problem.choices,
                         answer: (problem.answerIndex ?? 0) + 1, points: 1, source: source)
        case .shortAnswer, .essay:
            QuizQuestion(id: id, type: .shortAnswer, prompt: problem.question, answers: distinctAnswers(problem.acceptedAnswers),
                         points: 1, source: source)
        }
    }

    /// 채점에서 같은 답으로 보는 표기(공백·대소문자·문장부호만 다름)는 처음 것만 남긴다.
    /// 모델이 같은 정답을 여러 번 되풀이해 쓰는 경우가 있어 진행자가 검토하기 쉽게 정리한다.
    static func distinctAnswers(_ answers: [String]) -> [String] {
        var seen = Set<[Character]>()
        return answers.filter { answer in
            let key = QuoteVerifier.normalize(answer)
            return !key.isEmpty && seen.insert(key).inserted
        }
    }

    private func candidates(setId: String) throws -> ([Chunk], [String: Document]) {
        try generator.database.writer.read { db in
            let documents = try Document
                .filter(Column("setId") == setId && Column("status") == DocumentStatus.indexed.rawValue)
                .order(Column("importedAt"))
                .fetchAll(db)
            let order = Dictionary(uniqueKeysWithValues: documents.enumerated().map { ($0.element.id, $0.offset) })
            let chunks = try Chunk
                .filter(documents.map(\.id).contains(Column("documentId")))
                .fetchAll(db)
                .filter { ($0.text as NSString).length >= ProblemGenerator.minimumChunkLength }
                .sorted { (order[$0.documentId] ?? 0, $0.ordinal) < (order[$1.documentId] ?? 0, $1.ordinal) }
            return (chunks, Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) }))
        }
    }
}

extension QuizQuestionType {
    var problemType: ProblemType {
        switch self {
        case .multipleChoice: .multipleChoice
        case .shortAnswer: .shortAnswer
        }
    }
}
