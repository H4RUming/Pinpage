import Foundation

/// LLM에 보내는 프롬프트 템플릿 묶음. 코드에 넣지 않고 템플릿 파일에서 읽는다.
///
/// 파일 (이름 고정, 내용은 자유):
/// - `answer-system.md`, `answer-user.md`: 자유 질문 답변
/// - `hint-system.md`, `hint-1.md` … `hint-N.md`: 단계별 힌트 (N은 파일이 있는 만큼)
/// - `problem-system.md`, `problem-user.md`: 연습 문제 만들기
/// - `problem-check-system.md`, `problem-check-user.md`: 만든 객관식을 자료만으로 풀어 정답 검증
/// - `grade-system.md`, `grade-user.md`: 답안 채점
///
/// 자리표시자는 `{{이름}}` 형식이다 (파일마다 쓰는 이름은 각 기능의 코드 주석 참고).
public struct PromptTemplates: Equatable, Sendable {
    public let answerSystem: String
    public let answerUser: String
    public let hintSystem: String
    /// 1단계부터 순서대로
    public let hints: [String]
    public let problemSystem: String
    public let problemUser: String
    public let problemCheckSystem: String
    public let problemCheckUser: String
    public let gradeSystem: String
    public let gradeUser: String

    public init(answerSystem: String, answerUser: String, hintSystem: String, hints: [String],
                problemSystem: String = "", problemUser: String = "", problemCheckSystem: String = "",
                problemCheckUser: String = "", gradeSystem: String = "", gradeUser: String = "") {
        self.answerSystem = answerSystem
        self.answerUser = answerUser
        self.hintSystem = hintSystem
        self.hints = hints
        self.problemSystem = problemSystem
        self.problemUser = problemUser
        self.problemCheckSystem = problemCheckSystem
        self.problemCheckUser = problemCheckUser
        self.gradeSystem = gradeSystem
        self.gradeUser = gradeUser
    }

    /// `name`(확장자 제외)으로 템플릿 내용을 찾는 함수로 읽는다 (앱 번들, 폴더, 테스트 모두 같은 방식).
    public init(loader: (String) -> String?) throws(PromptTemplateError) {
        func required(_ name: String) throws(PromptTemplateError) -> String {
            guard let text = loader(name), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw .missing(name)
            }
            return text
        }
        answerSystem = try required("answer-system")
        answerUser = try required("answer-user")
        hintSystem = try required("hint-system")
        var hints: [String] = []
        while let text = loader("hint-\(hints.count + 1)") { hints.append(text) }
        guard !hints.isEmpty else { throw .missing("hint-1") }
        self.hints = hints
        problemSystem = try required("problem-system")
        problemUser = try required("problem-user")
        problemCheckSystem = try required("problem-check-system")
        problemCheckUser = try required("problem-check-user")
        gradeSystem = try required("grade-system")
        gradeUser = try required("grade-user")
    }

    /// 앱 번들의 템플릿.
    public static func bundled(_ bundle: Bundle) throws(PromptTemplateError) -> PromptTemplates {
        try PromptTemplates { name in
            bundle.url(forResource: name, withExtension: "md").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }
    }

    /// 로그에 남기는 템플릿 식별값. 문구가 한 글자라도 바뀌면 달라진다.
    public var fingerprint: String {
        var hash: UInt64 = 0xcbf29ce484222325  // FNV-1a
        for part in [answerSystem, answerUser, hintSystem] + hints + [problemSystem, problemUser, problemCheckSystem, problemCheckUser, gradeSystem, gradeUser] {
            for byte in part.utf8 {
                hash ^= UInt64(byte)
                hash &*= 0x100000001b3
            }
            hash ^= 0xff
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    /// `{{이름}}`을 값으로 바꾼다. 남은 자리표시자가 있으면 오류.
    public static func render(_ template: String, _ values: [String: String]) throws(PromptTemplateError) -> String {
        var text = template
        for (key, value) in values {
            text = text.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        if let range = text.range(of: #"\{\{[^}]*\}\}"#, options: .regularExpression) {
            throw .unresolved(String(text[range]))
        }
        return text
    }
}

public enum PromptTemplateError: Error, LocalizedError, Equatable {
    case missing(String)
    case unresolved(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let name): "프롬프트 템플릿 '\(name).md'이(가) 없거나 비어 있습니다."
        case .unresolved(let placeholder): "프롬프트 템플릿에 채울 수 없는 자리표시자 \(placeholder)가 있습니다."
        }
    }
}
