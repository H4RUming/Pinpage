import Foundation

/// 설정 값의 허용 범위. 설정 화면과 불러오기 검증이 같은 범위를 쓴다.
public enum SettingsLimits {
    public static let testTimeoutSeconds = 1...120
    public static let requestTimeoutSeconds = 5...600
    public static let maxRetries = 0...10
    public static let chunkSize = 100...8000
    public static let chunkOverlap = 0...2000
    public static let topK = 1...50
    public static let embeddingWeight = 0.0...1.0
    public static let quizPassThreshold = 0.0...1.0
    public static let hintLevels = 1...5
}

public struct SettingsIssue: Equatable, Sendable {
    /// 화면에 보여줄 항목 이름.
    public let field: String
    public let message: String

    public init(field: String, message: String) {
        self.field = field
        self.message = message
    }

    public var description: String { "\(field): \(message)" }
}

extension AppSettings {
    /// 잘못된 값을 모두 찾아 돌려준다. 비어 있으면 문제 없음.
    public func validate() -> [SettingsIssue] {
        var issues: [SettingsIssue] = []

        func checkURL(_ value: String, field: String) {
            guard !value.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            do {
                _ = try APIEndpoint(baseURL: value)
            } catch {
                issues.append(SettingsIssue(field: field, message: error.message))
            }
        }

        func checkRange<T: Comparable>(_ value: T, _ range: ClosedRange<T>, field: String) {
            if !range.contains(value) {
                issues.append(SettingsIssue(field: field, message: "\(range.lowerBound)~\(range.upperBound) 사이여야 합니다 (현재 \(value))."))
            }
        }

        checkURL(chat.baseURL, field: "Chat API 주소")
        if !embedding.useChatServer {
            checkURL(embedding.baseURL, field: "임베딩 API 주소")
        }

        checkRange(network.testTimeoutSeconds, SettingsLimits.testTimeoutSeconds, field: "연결 테스트 시간 제한(초)")
        checkRange(network.requestTimeoutSeconds, SettingsLimits.requestTimeoutSeconds, field: "답변 생성 시간 제한(초)")
        checkRange(network.maxRetries, SettingsLimits.maxRetries, field: "최대 재시도 횟수")

        checkRange(retrieval.chunkSize, SettingsLimits.chunkSize, field: "청크 크기")
        checkRange(retrieval.chunkOverlap, SettingsLimits.chunkOverlap, field: "청크 겹침")
        if retrieval.chunkOverlap >= retrieval.chunkSize {
            issues.append(SettingsIssue(field: "청크 겹침", message: "청크 크기(\(retrieval.chunkSize))보다 작아야 합니다."))
        }
        checkRange(retrieval.topK, SettingsLimits.topK, field: "검색 결과 개수")
        checkRange(retrieval.embeddingWeight, SettingsLimits.embeddingWeight, field: "임베딩 검색 비중")

        checkRange(learning.quizPassThreshold, SettingsLimits.quizPassThreshold, field: "퀴즈 통과 기준")
        checkRange(learning.hintLevels, SettingsLimits.hintLevels, field: "힌트 단계 수")

        return issues
    }

    /// Chat API 접속 정보.
    public func chatEndpoint() throws(EndpointError) -> APIEndpoint {
        try APIEndpoint(baseURL: chat.baseURL, apiKey: chat.apiKey)
    }

    /// 임베딩 API 접속 정보. "Chat API와 같은 서버"면 Chat 주소와 키를 쓴다.
    public func embeddingEndpoint() throws(EndpointError) -> APIEndpoint {
        if embedding.useChatServer {
            return try chatEndpoint()
        }
        return try APIEndpoint(baseURL: embedding.baseURL, apiKey: embedding.apiKey)
    }

    /// 임베딩 검색을 쓸 수 있는지. false면 BM25만으로 검색한다.
    public var isEmbeddingConfigured: Bool {
        !embedding.model.isEmpty && (try? embeddingEndpoint()) != nil
    }
}
