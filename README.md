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
  Problems/                 AI 연습 문제 생성(정답 검증 포함)과 채점
  Logging/                  이벤트 로그와 이벤트 내용 형식
  Experiment/               실험 세션, 퀴즈 파일·채점, 경과 시간, 사전 퀴즈 만들기
  Export/                   로그 내보내기 (zip, JSONL, 세션 요약·문항별 CSV)
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

개발·검증 때 실제 데이터를 건드리지 않으려면 환경 변수 `PINPAGE_DATA_DIR`로 다른 폴더를 지정합니다
(예: `open -g --env PINPAGE_DATA_DIR=/tmp/pinpage-check build/.../Pinpage.app`).

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

## 연습 문제와 이벤트 로그

- 연습 문제는 AI가 학습 자료에서 만듭니다(객관식·단답형·서술형). 채점 요점마다 자료 인용이 붙고, 인용이 확인되지 않으면 버립니다.
- 객관식은 만든 뒤 같은 모델이 자료만 보고 직접 풀어(temperature 0) 정답 번호가 맞는지 확인합니다.
- 출제 위치: 채점에서 빠진 요점이 나온 부분(최대 3번) → 아직 안 낸 부분 → 가장 적게 낸 부분. 다음 문제는 미리 만들어 둡니다.
- 채점: 객관식은 코드, 단답형은 정답 목록 비교 후 AI, 서술형은 AI. 빠진 요점은 근거 위치로만 보여줍니다.
- 참가자마다 연습 문제가 달라도 됩니다(학습 과정). 같아야 하는 결과 측정은 진행자가 만든 퀴즈 JSON입니다.
- 모든 행동을 `event` 테이블에 즉시 기록합니다(UTC 밀리초, 순번). 문제 전문, 답안, 채점, 질문, 검색 청크, 힌트, 근거 열기, LLM 시도별 지연·재시도·실패, 앱 일시정지·재개.
  설정 탭 아래 "최근 이벤트"에서 확인할 수 있습니다.

## 실험 세션

- 시작할 때 참가자 ID(실명 대신), 세션 종류(학습 / 최종 시험 / 재시험), 조건(도구 / 대조), 학습 세트, 퀴즈 파일을 고릅니다.
- 학습 세션: 사전 퀴즈(퀴즈 파일에 있으면, 처음 시작할 때 한 번) → 학습 → 체크포인트 퀴즈. 통과 기준 이상이면 끝,
  떨어지면 총점만 보여주고 다시 학습합니다(틀린 문제와 정답은 보여주지 않음, 재응시 횟수 제한 없음).
- 도구 조건은 사전 퀴즈 점수로 연습 문제 난이도를 정합니다(설정의 기초·심화 기준). 대조 조건은 AI 기능 없이 자료 뷰어만 씁니다.
  두 조건 모두 같은 뷰어(문서 고르기, 쪽 표시, 문서 안 찾기 ⌘F)를 씁니다.
- 최종 시험·재시험: 자료와 AI를 숨기고 한 번 응시합니다.
- 퀴즈는 AI 없이 코드로 채점합니다. 형식은 [docs/quiz-format.md](docs/quiz-format.md), 예시는 [Examples/quiz-example.json](Examples/quiz-example.json).
- 경과 시간은 앱이 켜져 있는 시간만 단계별(사전 퀴즈, 학습, 퀴즈)로 셉니다. 시스템 가동 시간 기준이라 Mac이 잠든 동안과
  앱이 꺼진 동안은 멈춥니다. 다른 앱으로 전환한 시간은 포함하되 따로 쌓습니다. 5초마다 저장하므로 강제 종료돼도 잃는 시간은 5초 이내입니다.
- 앱을 다시 열면 진행 중인 세션의 단계, 경과 시간, 풀던 퀴즈의 답이 그대로 돌아옵니다. 꺼져 있던 시간과 강제 종료 여부를 기록합니다.
- 세션 중에는 학습 세트·학습 탭이 숨겨지고 설정이 잠깁니다.
- 세션 시작 기록에 설정 스냅샷(API 키 제외)과 서버 주소를 뺀 설정 해시, 프롬프트 템플릿 지문, 자료 PDF의 SHA-256,
  퀴즈 파일 SHA-256이 남습니다. 진행자는 이 값으로 모든 참가자가 같은 조건이었는지 확인할 수 있습니다.
- 사전 퀴즈는 진행자가 학습 세트 화면의 ⋯ → [사전 퀴즈 만들기]로 한 번 만들어 검토한 뒤 퀴즈 파일로 나눠 줍니다.
  같은 요청을 temperature 0, 같은 seed로 보내도 서버가 여러 요청을 함께 처리하면 결과가 달라지므로, 참가자 앱에서 만들지 않습니다.

## 로그 내보내기

- 실험 세션 탭(또는 세션 종료 화면)의 [로그 내보내기…]에서 참가자 ID를 골라 zip 파일 하나로 저장합니다. 진행자용으로 이 Mac의 전체 기록도 고를 수 있습니다.
- zip 안: `manifest.json`(앱 버전, 모델, 내보낸 시각, 파일별 SHA-256), `events.jsonl`(원본 이벤트), `sessions.csv`(세션 요약: 통과까지 걸린 시간, 질문 수, 힌트 단계 분포, 점수 등), `quiz_items.csv`(문항별 퀴즈 응답).
- 파일 이름과 내용에 참가자 ID, 앱 버전, 모델, 내보낸 시각이 들어갑니다. CSV는 UTF-8 BOM 포함이고 모든 참가자 파일의 열 구성이 같습니다. API 키는 들어가지 않습니다.
- 열 정의와 합치는 방법: [docs/log-format.md](docs/log-format.md)

## 가짜 서버로 확인하기

```bash
python3 Tools/mock_openai_server.py --port 18000
```

설정 탭 주소에 `localhost:18000`을 넣으면 모델 목록과 연결 테스트를 확인할 수 있습니다.
`--require-key`, `--delay`, `--fail-first` 옵션으로 인증 오류, 시간 초과, 재시도를 재현할 수 있습니다.
