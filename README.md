# Pinpage

문제를 먼저 풀고 막힌 지점에서 질문하면, AI가 학습 자료(PDF, 코드) 안의 정확한 위치를 짚어주는 macOS 학습 앱입니다.
명세는 [SPEC.md](SPEC.md)를 보세요.

## 개발 환경

- macOS 14 이상, Xcode 16 이상 (Swift 6)
- XcodeGen: `brew install xcodegen`

```bash
make test      # 핵심 로직 테스트 (Packages/PinpageCore)
make run       # Xcode 프로젝트 생성 → Debug 빌드 → 실행
make release   # Release Universal 빌드 (Apple Silicon + Intel)
```

`Pinpage.xcodeproj`와 `App/Info.plist`는 `project.yml`에서 생성하므로 git에 넣지 않습니다.
Xcode로 작업하려면 `make project` 후 `Pinpage.xcodeproj`를 여세요.

## 구조

```
project.yml                 XcodeGen 프로젝트 정의 (ATS 예외, 샌드박스 끔, Universal 빌드)
Packages/PinpageCore/       UI 없는 핵심 로직과 테스트
  Settings/                 설정 모델, 검증, 저장, 내보내기·불러오기
  LLM/                      주소 정규화, OpenAI 호환 클라이언트, 재시도, 한국어 오류 메시지
App/                        SwiftUI 앱 (설정 탭 등 화면)
Tools/mock_openai_server.py 개발용 가짜 OpenAI 호환 서버
```

## 데이터 위치

`~/Library/Application Support/Pinpage/`

- `settings.json`: 설정 (API 키 포함, 권한 600). 설정 내보내기 파일에는 API 키가 들어가지 않습니다.

## LLM 서버 주소

- OpenAI 호환 API(`/v1/models`, `/v1/chat/completions`, `/v1/embeddings`)를 씁니다.
- `gpu-server:8000`처럼 스킴 없이 입력하면 `http://`를 붙이고, `/v1`로 끝나지 않으면 `/v1`을 붙입니다.
- API 키를 비워두면 `Authorization` 헤더를 보내지 않습니다 (로컬 IP, Tailscale 서버).
- Tailscale MagicDNS 짧은 이름(`gpu-server`)도 그대로 쓸 수 있습니다.

## 가짜 서버로 확인하기

```bash
python3 Tools/mock_openai_server.py --port 18000
```

설정 탭 주소에 `localhost:18000`을 넣으면 모델 목록과 연결 테스트를 확인할 수 있습니다.
`--require-key`, `--delay`, `--fail-first` 옵션으로 인증 오류, 시간 초과, 재시도를 재현할 수 있습니다.
