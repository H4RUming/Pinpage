# Pinpage

문제를 먼저 풀고 막힌 지점에서 질문하면, AI가 학습 자료(PDF, 코드) 안의 정확한 위치를 짚어주는 macOS 학습 앱입니다.
명세는 [SPEC.md](SPEC.md)를 보세요.

## 개발 환경

- Apple Silicon Mac, macOS 15 이상, Xcode 16 이상 (Swift 6)
- XcodeGen: `brew install xcodegen`

```bash
make test      # 핵심 로직 테스트 (Packages/PinpageCore)
make run       # Xcode 프로젝트 생성 → Debug 빌드 → 실행
make release   # Release 빌드 (Apple Silicon 전용)
```

`Pinpage.xcodeproj`와 `App/Info.plist`는 `project.yml`에서 생성하므로 git에 넣지 않습니다.
Xcode로 작업하려면 `make project` 후 `Pinpage.xcodeproj`를 여세요.

## 구조

```
project.yml                 XcodeGen 프로젝트 정의 (ATS 예외, 샌드박스 끔, arm64 전용)
Packages/PinpageCore/       UI 없는 핵심 로직과 테스트
  Settings/                 설정 모델, 검증, 저장, 내보내기·불러오기
  LLM/                      주소 정규화, OpenAI 호환 클라이언트, 재시도, 한국어 오류 메시지
  Storage/                  DB(GRDB), 학습 세트·문서·청크·임베딩, 자료 파일 관리
  Ingest/                   PDF 텍스트·OCR 추출, 문단 나누기, 청크 나누기, 색인
  Search/                   BM25(한글 음절 바이그램), 하이브리드 검색
  Embedding/                Gemma 토크나이저, Core ML·원격 임베더, 모델 설치
  Answering/                근거 인용 답변·단계별 힌트, 인용 검증, PDF 강조 위치 찾기
App/                        SwiftUI 앱 (학습 세트, 설정 화면)
Tools/                      가짜 OpenAI 서버, 임베딩 모델 준비·검증 스크립트
```

## 데이터 위치

`~/Library/Application Support/Pinpage/`

- `settings.json`: 설정 (API 키 포함, 권한 600). 설정 내보내기 파일에는 API 키가 들어가지 않습니다.
  처음 실행하면 앱에 들어 있는 `App/Resources/DefaultSettings.json`(임베딩 모델 저장소·고정 버전 등)으로 시작합니다.
- `pinpage.sqlite`: 학습 세트, 문서, 청크(페이지·문단·위치), 임베딩 (WAL 모드)
- `sets/`: 학습 세트에 넣은 자료 파일 사본
- `models/`: 처음 설정할 때 내려받은 임베딩 모델 (Hugging Face 고정 버전, SHA-256 검증)

## 임베딩 모델

- 앱 내장 임베딩은 `google/embeddinggemma-2`의 Core ML 변환본을 씁니다. 검증 결과는 [docs/embedding-spike.md](docs/embedding-spike.md).
- 앱은 처음 설정할 때 Hugging Face(`H4RUming/embeddinggemma-2-coreml-text`, 고정 버전)에서 모델을 내려받습니다.
  인터넷이 없으면 설정 탭의 [폴더에서 설치…]로 같은 폴더를 설치할 수 있습니다.
- 업로드 폴더 만들기: `python3 Tools/prepare_embedding_model.py dist/embedding-model`
- 임베딩 프롬프트는 `App/Resources/embedding-prompts.json`에 있습니다 (코드에 넣지 않음).
- 모델이 필요한 테스트는 `dist/embedding-model`(또는 `PINPAGE_EMBEDDING_MODEL_DIR`)이 있을 때만 돕니다.

## LLM 서버 주소

- OpenAI 호환 API(`/v1/models`, `/v1/chat/completions`, `/v1/embeddings`)를 씁니다.
- `gpu-server:8000`처럼 스킴 없이 입력하면 `http://`를 붙이고, `/v1`로 끝나지 않으면 `/v1`을 붙입니다.
- API 키를 비워두면 `Authorization` 헤더를 보내지 않습니다 (로컬 IP, Tailscale 서버).
- Tailscale MagicDNS 짧은 이름(`gpu-server`)도 그대로 쓸 수 있습니다.

## 답변과 힌트

- 질문 → 하이브리드 검색 → 번호 붙인 근거와 함께 LLM에 요청 → JSON(`status`, `answer`, `citations[{source, quote}]`)으로 받습니다.
- 인용이 실제로 근거 청크에 있는지 앱이 검증합니다. 확인되지 않은 인용은 버리고, 남는 근거가 없으면 "자료에 없음"으로 답합니다.
- 근거를 누르면 PDF 뷰어가 해당 쪽으로 이동해 인용 문장을 강조합니다 (OCR 페이지는 영역 강조).
- 힌트 1단계는 위치만(문구는 앱이 만듦), 2단계는 설명, 3단계는 정답과 풀이입니다.
- 프롬프트는 `App/Resources/PromptTemplates/*.md`에 있습니다. 템플릿 식별값은 결과와 함께 기록합니다.
- Qwen 같은 추론 모델은 설정의 추가 요청 파라미터로 추론을 끄는 것을 권장합니다
  (`{"chat_template_kwargs": {"enable_thinking": false}}`). 실측에서 켜면 17초에 오답, 끄면 3.8초에 정답이었습니다.

## 가짜 서버로 확인하기

```bash
python3 Tools/mock_openai_server.py --port 18000
```

설정 탭 주소에 `localhost:18000`을 넣으면 모델 목록과 연결 테스트를 확인할 수 있습니다.
`--require-key`, `--delay`, `--fail-first` 옵션으로 인증 오류, 시간 초과, 재시도를 재현할 수 있습니다.
