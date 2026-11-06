import CryptoKit
import Foundation

/// 퀴즈 종류. 퀴즈 파일 하나에 종류마다 하나씩 넣는다.
public enum QuizKind: String, Codable, CaseIterable, Sendable {
    /// 학습 세션을 처음 시작할 때 (도구 조건은 점수로 연습 문제 난이도를 정한다)
    case pre
    /// 학습 세션 중 원할 때 응시, 통과하면 세션 종료
    case checkpoint
    /// 최종 시험 세션
    case final
    /// 재시험 세션
    case retest

    public var label: String {
        switch self {
        case .pre: "사전 퀴즈"
        case .checkpoint: "체크포인트 퀴즈"
        case .final: "최종 시험"
        case .retest: "재시험"
        }
    }
}

public enum QuizQuestionType: String, Codable, CaseIterable, Sendable {
    case multipleChoice = "multiple_choice"
    case shortAnswer = "short_answer"

    public var label: String {
        switch self {
        case .multipleChoice: "객관식"
        case .shortAnswer: "단답형"
        }
    }
}

/// 퀴즈 문제 하나. 두 조건이 같은 문제를 풀어야 하므로 AI 없이 코드로만 채점한다.
public struct QuizQuestion: Codable, Equatable, Identifiable, Sendable {
    /// 퀴즈 안에서 겹치지 않는 식별자 (로그에 남는다)
    public var id: String
    public var type: QuizQuestionType
    public var prompt: String
    /// 객관식 보기
    public var choices: [String]?
    /// 객관식 정답 번호 (1부터)
    public var answer: Int?
    /// 단답형 정답들 (공백·대소문자·문장부호를 무시하고 하나라도 같으면 정답)
    public var answers: [String]?
    /// 배점 (1 이상의 정수, 없으면 1)
    public var points: Int?
    /// 참고용 출처. 앱은 쓰지 않는다 (사전 퀴즈 만들기가 근거 위치를 적어 둔다).
    public var source: String?

    public init(id: String, type: QuizQuestionType, prompt: String, choices: [String]? = nil, answer: Int? = nil,
                answers: [String]? = nil, points: Int? = nil, source: String? = nil) {
        self.id = id
        self.type = type
        self.prompt = prompt
        self.choices = choices
        self.answer = answer
        self.answers = answers
        self.points = points
        self.source = source
    }

    public var score: Int { points ?? 1 }
}

public struct Quiz: Codable, Equatable, Sendable {
    public var kind: QuizKind
    /// 화면에 보여줄 제목 (없으면 종류 이름)
    public var title: String?
    public var questions: [QuizQuestion]

    public init(kind: QuizKind, title: String? = nil, questions: [QuizQuestion]) {
        self.kind = kind
        self.title = title
        self.questions = questions
    }

    public var displayTitle: String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? kind.label : trimmed
    }

    public var totalPoints: Int { questions.reduce(0) { $0 + $1.score } }
}

/// 퀴즈 파일 (JSON). 형식은 docs/quiz-format.md 참고.
public struct QuizFile: Codable, Equatable, Sendable {
    public static let formatIdentifier = "pinpage-quiz"
    public static let currentFormatVersion = 1

    public var format: String
    public var formatVersion: Int
    /// 퀴즈 세트 식별자 (진행자가 정한다, 로그에 남는다)
    public var id: String
    public var title: String
    public var quizzes: [Quiz]

    public init(id: String, title: String, quizzes: [Quiz]) {
        format = Self.formatIdentifier
        formatVersion = Self.currentFormatVersion
        self.id = id
        self.title = title
        self.quizzes = quizzes
    }

    public func quiz(_ kind: QuizKind) -> Quiz? {
        quizzes.first { $0.kind == kind }
    }

    /// 같은 종류의 퀴즈를 바꾸거나 (없으면) 추가한다. 종류 순서(사전 → 체크포인트 → 최종 → 재시험)로 정렬한다.
    public func replacing(_ quiz: Quiz) -> QuizFile {
        var copy = self
        copy.quizzes = (quizzes.filter { $0.kind != quiz.kind } + [quiz]).sorted {
            QuizKind.allCases.firstIndex(of: $0.kind)! < QuizKind.allCases.firstIndex(of: $1.kind)!
        }
        return copy
    }

    // MARK: - 읽기와 검사

    /// 파일 내용을 읽고 검사한다. 문제가 있으면 위치를 짚은 한국어 메시지로 알려준다.
    public static func load(_ data: Data) throws(QuizFileError) -> QuizFile {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw .notJSON
        }
        guard object["format"] as? String == formatIdentifier else { throw .wrongFormat }
        if let version = object["formatVersion"] as? Int, version > currentFormatVersion {
            throw .newerFormat(version)
        }
        let file: QuizFile
        do {
            file = try JSONDecoder().decode(QuizFile.self, from: data)
        } catch let error as DecodingError {
            throw Self.describe(error)
        } catch {
            throw .notJSON
        }
        let issues = file.validate()
        guard issues.isEmpty else { throw .invalid(issues) }
        return file
    }

    /// 잘못된 내용을 모두 찾아 돌려준다. 비어 있으면 문제 없음.
    public func validate() -> [QuizIssue] {
        var issues: [QuizIssue] = []
        func blank(_ text: String?) -> Bool { (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        if blank(id) { issues.append(QuizIssue(location: "파일", message: "id가 비어 있습니다.")) }
        if blank(title) { issues.append(QuizIssue(location: "파일", message: "title이 비어 있습니다.")) }
        if quizzes.isEmpty { issues.append(QuizIssue(location: "파일", message: "quizzes에 퀴즈가 하나도 없습니다.")) }

        var seenKinds = Set<QuizKind>()
        for quiz in quizzes {
            if !seenKinds.insert(quiz.kind).inserted {
                issues.append(QuizIssue(location: quiz.kind.label, message: "같은 종류(\(quiz.kind.rawValue))의 퀴즈가 두 번 이상 있습니다."))
            }
            if quiz.questions.isEmpty {
                issues.append(QuizIssue(location: quiz.kind.label, message: "문제가 하나도 없습니다."))
            }
            var seenIds = Set<String>()
            for (index, question) in quiz.questions.enumerated() {
                let location = "\(quiz.kind.label) \(index + 1)번 문제" + (blank(question.id) ? "" : " (id: \(question.id))")
                func issue(_ message: String) { issues.append(QuizIssue(location: location, message: message)) }

                if blank(question.id) {
                    issue("id가 비어 있습니다.")
                } else if !seenIds.insert(question.id).inserted {
                    issue("같은 퀴즈 안에 id가 겹칩니다.")
                }
                if blank(question.prompt) { issue("prompt(문제)가 비어 있습니다.") }
                if question.score < 1 { issue("points(배점)는 1 이상의 정수여야 합니다 (현재 \(question.score)).") }

                switch question.type {
                case .multipleChoice:
                    let choices = question.choices ?? []
                    if !(2...10).contains(choices.count) {
                        issue("choices(보기)는 2~10개여야 합니다 (현재 \(choices.count)개).")
                    }
                    if choices.contains(where: { blank($0) }) { issue("빈 보기가 있습니다.") }
                    let normalized = choices.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    if Set(normalized).count != normalized.count { issue("같은 보기가 두 번 이상 있습니다.") }
                    if let answer = question.answer {
                        if !choices.isEmpty && !(1...choices.count).contains(answer) {
                            issue("정답 번호 \(answer)가 보기 수(\(choices.count))를 벗어납니다. 번호는 1부터 셉니다.")
                        }
                    } else {
                        issue("객관식은 answer(정답 번호, 1부터)가 있어야 합니다.")
                    }
                    if !(question.answers ?? []).isEmpty { issue("객관식에는 answers를 쓰지 않습니다. 정답 번호는 answer에 넣으세요.") }
                case .shortAnswer:
                    let answers = question.answers ?? []
                    if answers.isEmpty {
                        issue("단답형은 answers(인정할 정답 목록)가 있어야 합니다.")
                    } else if answers.contains(where: { QuoteVerifier.normalize($0).isEmpty }) {
                        issue("글자나 숫자가 없는 정답이 있습니다 (공백과 문장부호는 채점에서 무시합니다).")
                    }
                    if question.answer != nil { issue("단답형에는 answer를 쓰지 않습니다. 정답은 answers 목록에 넣으세요.") }
                    if !(question.choices ?? []).isEmpty { issue("단답형에는 choices를 쓰지 않습니다.") }
                }
            }
        }
        return issues
    }

    /// 사람이 읽고 고치기 쉬운 JSON (들여쓰기, 키 정렬).
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func describe(_ error: DecodingError) -> QuizFileError {
        func location(_ path: [CodingKey]) -> String {
            guard !path.isEmpty else { return "파일" }
            return path.map { key in
                key.intValue.map { "\($0 + 1)번째" } ?? key.stringValue
            }.joined(separator: " → ")
        }
        switch error {
        case .keyNotFound(let key, let context):
            return .malformed(location: location(context.codingPath), message: "'\(key.stringValue)' 항목이 없습니다.")
        case .valueNotFound(_, let context):
            return .malformed(location: location(context.codingPath), message: "값이 비어 있습니다(null).")
        case .typeMismatch(let type, let context):
            let expected: String = switch type {
            case is Int.Type: "정수"
            case is String.Type: "문자열"
            case is [Any].Type, is [String].Type: "목록([...])"
            default: "다른 형식"
            }
            return .malformed(location: location(context.codingPath), message: "\(expected)이어야 합니다.")
        case .dataCorrupted(let context):
            let message: String = switch context.codingPath.last?.stringValue {
            case "kind": "kind는 pre, checkpoint, final, retest 중 하나여야 합니다."
            case "type": "type은 multiple_choice, short_answer 중 하나여야 합니다."
            default: "값을 읽을 수 없습니다."
            }
            return .malformed(location: location(context.codingPath), message: message)
        @unknown default:
            return .notJSON
        }
    }
}

public struct QuizIssue: Equatable, Sendable {
    public let location: String
    public let message: String

    public init(location: String, message: String) {
        self.location = location
        self.message = message
    }

    public var description: String { "\(location): \(message)" }
}

public enum QuizFileError: Error, LocalizedError, Equatable {
    case notJSON
    case wrongFormat
    case newerFormat(Int)
    case malformed(location: String, message: String)
    case invalid([QuizIssue])

    public var errorDescription: String? {
        switch self {
        case .notJSON:
            "JSON 파일을 읽을 수 없습니다. 쉼표나 따옴표가 빠지지 않았는지 확인하세요."
        case .wrongFormat:
            "Pinpage 퀴즈 파일이 아닙니다. \"format\": \"pinpage-quiz\"가 있어야 합니다."
        case .newerFormat(let version):
            "이 앱보다 새로운 형식(버전 \(version))의 퀴즈 파일입니다. 앱을 최신 버전으로 바꾼 뒤 불러오세요."
        case .malformed(let location, let message):
            "퀴즈 파일 형식이 맞지 않습니다.\n• \(location): \(message)"
        case .invalid(let issues):
            "퀴즈 파일에 고칠 곳이 있습니다.\n" + issues.map { "• " + $0.description }.joined(separator: "\n")
        }
    }
}
