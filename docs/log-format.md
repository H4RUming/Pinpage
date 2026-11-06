# 로그 내보내기 형식

참가자는 세션을 모두 마친 뒤 **실험 세션 탭 → [로그 내보내기…]**에서 자기 참가자 ID를 골라 zip 파일 하나를 저장하고, 그 파일을 진행자에게 보냅니다.
세션 종료 화면의 [로그 내보내기…]를 누르면 방금 끝난 참가자가 미리 선택되어 있습니다. 세션 중에는 내보낼 수 없습니다.

모든 참가자 파일의 열 구성과 형식이 같으므로 진행자는 CSV를 그대로 이어 붙이면 됩니다.

## 내보내기 범위

| 선택 | 담기는 것 |
|---|---|
| 참가자 ID (기본) | 그 참가자의 세션, 세션 중에 남은 이벤트, 그 세션들의 퀴즈 응답. 같은 Mac에서 쓴 다른 ID와 세션 밖 기록(설정 탭의 연결 테스트 등)은 빠집니다 |
| 이 Mac의 전체 기록 (진행자용) | 모든 참가자 ID의 세션과 세션 밖 이벤트까지 모두 |

세션 밖 이벤트(세션을 시작하기 전의 앱 실행·종료 등)는 참가자 단위 파일에 들어가지 않습니다.
진행 중인 세션이 있는 상태로 앱을 다시 열면, 그때의 앱 실행 기록(`app_launch`)에는 세션 ID가 붙어 참가자 파일에 들어갑니다.

## 파일 이름

```
pinpage-log_<참가자ID>_v<앱 버전>_<모델>_<내보낸 시각 UTC>.zip
예: pinpage-log_P01_v0.1.0_qwen3.5-27b_20261106T063012Z.zip
```

- 전체 기록은 참가자 자리에 `all`이 들어갑니다.
- 모델은 그 기록의 세션에서 쓴 Chat 모델입니다(여럿이면 `+`로 이어 붙임, 세션이 없으면 내보낼 때의 설정 모델). 영문, 숫자, 점, 하이픈 말고는 하이픈으로 바뀌므로 정확한 값은 `manifest.json`을 보세요.
- 같은 참가자를 여러 번 내보내면 시각만 다른 파일이 생깁니다. 내보낼 때마다 `log_exported` 이벤트가 남습니다.

## zip 안의 파일

| 파일 | 내용 |
|---|---|
| `manifest.json` | 내보낸 범위, 앱 버전·빌드, 모델, 내보낸 시각(UTC와 이 Mac의 시간대), macOS 버전, 세션 id 목록, 파일별 줄 수·바이트·SHA-256, CSV 열 목록 |
| `events.jsonl` | 원본 이벤트 로그. 한 줄에 이벤트 하나 |
| `sessions.csv` | 세션 하나가 한 줄인 요약 |
| `quiz_items.csv` | 제출한 퀴즈 응시의 문제 하나가 한 줄 |

- zip은 압축하지 않고 묶기만 합니다(Finder, `unzip`, Python `zipfile`로 열림).
- API 키는 어느 파일에도 들어가지 않습니다. 서버 주소(설정 스냅샷, LLM 요청 기록)는 들어갑니다.
- 받은 파일이 손상되지 않았는지는 `manifest.json`의 SHA-256과 각 파일의 SHA-256을 비교해 확인합니다.
  zip 파일 자체의 SHA-256은 내보내기 완료 화면에 보이고, 참가자 Mac의 `log_exported` 이벤트에 남습니다(세션 밖 이벤트이므로 전체 기록 내보내기에만 들어감).

## CSV 공통 형식

- UTF-8, BOM 포함 (Excel에서 한글이 깨지지 않음). 쉼표 구분, 줄 끝 CRLF.
- 쉼표, 큰따옴표, 줄바꿈이 든 값은 큰따옴표로 감싸고, 안의 큰따옴표는 두 번 씁니다(RFC 4180).
- 시각은 UTC, 밀리초까지: `2026-11-06T03:12:45.123Z`
- 시간 길이는 밀리초 정수.
- 참·거짓은 `true` / `false`. 비율은 0~1, 소수점 넷째 자리까지(`0.6667`).
- **횟수 열은 항상 숫자**입니다(해당 없으면 0, 예: 대조 조건의 질문 수). **해당 없는 점수·시각 열은 빈 칸**입니다(예: 학습 세션의 시험 점수, 대조 조건의 연습 난이도, 진행 중인 세션의 종료 시각).
- 열 구성은 데이터와 관계없이 고정입니다. 세션이 하나도 없어도 헤더는 같습니다.

## sessions.csv

### 식별

| 열 | 뜻 |
|---|---|
| `participant_id` | 참가자 ID |
| `session_id` | 세션 id (모든 파일에서 같은 세션을 잇는 키) |
| `condition` | `tool`(도구) / `control`(대조) |
| `session_kind` | `learning`(학습) / `final`(최종 시험) / `retest`(재시험) |
| `set_name` | 학습 세트 이름 (시험 세션은 빈 칸) |
| `quiz_id` | 퀴즈 파일 안의 `id` |
| `quiz_sha256` | 퀴즈 파일 SHA-256. 모든 참가자가 같아야 합니다 |
| `app_version` | 세션을 진행한 앱 버전 |
| `model` | 세션 시작 때의 Chat 모델 |
| `settings_hash` | 서버 주소와 API 키를 뺀 설정의 SHA-256. 모든 참가자가 같아야 같은 설정입니다 |
| `exported_at` | 내보낸 시각 |

### 시각과 시간

| 열 | 뜻 |
|---|---|
| `started_at`, `ended_at` | 세션 시작·종료 시각 |
| `end_reason` | `passed`(체크포인트 통과) / `completed`(시험 제출) / `abandoned`(중단) / `in_progress`(끝나지 않음) |
| `pre_quiz_ms` | 사전 퀴즈를 푼 시간 |
| `study_ms` | 학습 시간 (자료 보기, 연습 문제, 질문) |
| `quiz_ms` | 체크포인트 퀴즈(재응시 포함)·최종 시험·재시험을 푼 시간 |
| `background_ms` | 위 시간 중 앱이 맨 앞에 있지 않았던 시간 (위 세 시간에 이미 포함) |
| `time_to_pass_ms` | 학습 세션에서 통과했을 때만: `study_ms + quiz_ms` (사전 퀴즈 제외) |
| `downtime_ms` | 앱이 꺼져 있던 시간의 합 (경과 시간에는 넣지 않음) |
| `resume_count` | 세션 중 앱을 다시 연 횟수 |
| `unclean_exit_count` | 그중 지난번에 강제 종료(또는 충돌)되었던 횟수 |

경과 시간은 앱이 켜져 있는 동안만 셉니다. Mac이 잠든 동안과 앱이 꺼진 동안은 멈춥니다.

### 퀴즈

| 열 | 뜻 |
|---|---|
| `pre_quiz_earned`, `pre_quiz_total`, `pre_quiz_ratio` | 사전 퀴즈 득점, 전체 배점, 비율 (퀴즈 파일에 사전 퀴즈가 없으면 빈 칸) |
| `practice_difficulty` | 도구 조건의 연습 문제 난이도 1~3 (대조 조건은 빈 칸) |
| `checkpoint_attempts` | 체크포인트 퀴즈를 제출한 횟수 (학습 세션이 아니면 0) |
| `checkpoint_passed` | 통과했는지 (학습 세션이 아니면 빈 칸) |
| `checkpoint_last_earned`, `checkpoint_last_total`, `checkpoint_last_ratio` | 마지막 체크포인트 응시의 점수 |
| `exam_earned`, `exam_total`, `exam_ratio`, `exam_passed` | 최종 시험·재시험 점수와 통과 기준 이상인지 (학습 세션은 빈 칸) |

### 도구 사용 (대조 조건과 시험 세션은 0)

| 열 | 뜻 |
|---|---|
| `questions_asked` | 질문한 횟수 |
| `not_in_materials` | 그중 "자료에 없음"으로 답한 횟수 |
| `hint_level_1` ~ `hint_level_5` | 힌트를 단계별로 요청한 횟수. 설정의 최대값(5단계)까지 열을 고정합니다. 설정이 3단계면 4·5단계는 0 |
| `practice_shown` | 연습 문제를 보여준 수 |
| `practice_submissions` | 연습 문제 답을 제출한 횟수 (한 문제에 여러 번 낼 수 있음) |
| `practice_correct` | 그중 정답 판정 수 (= 맞힌 문제 수, 맞힌 문제는 다시 낼 수 없음) |
| `practice_skipped` | 풀지 않고 넘긴 문제 수 |
| `citations_opened` | 근거 위치를 눌러 자료를 연 횟수 |

### 자료 뷰어와 앱

| 열 | 뜻 |
|---|---|
| `documents_opened` | 자료 뷰어에서 문서를 연 횟수 (목록에서 고름 + 근거로 열림) |
| `document_searches` | 문서 안 찾기(⌘F) 검색 횟수 |
| `app_pauses` | 앱이 뒤로 가거나 Mac이 잠든 횟수 |
| `llm_calls` | Chat 요청 시도 수 (재시도 포함) |
| `llm_failures` | 재시도 끝에 최종 실패한 Chat 요청 수 |
| `llm_latency_ms_median` | 성공한 Chat 요청 응답 시간의 가운데 값 (짝수 개면 가운데 두 값의 평균) |

## quiz_items.csv

제출한 응시마다 퀴즈 파일의 문제 순서대로 한 줄씩 나옵니다. 제출하지 않고 중단한 응시는 들어가지 않습니다.

| 열 | 뜻 |
|---|---|
| `participant_id`, `session_id`, `condition`, `session_kind`, `quiz_id` | sessions.csv와 같음 |
| `quiz_kind` | `pre` / `checkpoint` / `final` / `retest` |
| `attempt_number` | 이 세션에서 같은 퀴즈의 몇 번째 응시인지 (체크포인트 재응시는 2, 3, …) |
| `question_number` | 퀴즈 안에서 몇 번째 문제인지 (1부터) |
| `question_id` | 퀴즈 파일의 문제 `id` |
| `question_type` | `multiple_choice` / `short_answer` |
| `response` | 객관식은 고른 번호(1부터), 단답형은 입력한 답. 답하지 않았으면 빈 칸 |
| `correct` | 정답 여부 |
| `points`, `earned` | 배점, 득점 |
| `attempt_active_ms` | 이 응시를 시작해 제출할 때까지 앱이 켜져 있던 시간 (같은 응시의 모든 줄에 같은 값) |
| `submitted_at` | 제출 시각 |

채점 결과는 제출할 때 남긴 `quiz_submitted` 이벤트를 그대로 씁니다.

## events.jsonl

```json
{"seq":12,"timestamp":"2026-11-06T03:12:45.123Z","type":"app_launch","sessionId":"…","participantId":"P01","appVersion":"0.1.0","payload":{"reason":"launch"}}
```

- 맨 위 키는 항상 이 7개, 이 순서입니다. 값이 없으면 `null` (세션 밖 이벤트의 `sessionId` 등).
- `seq`는 이 Mac의 DB에서 1부터 늘어나는 순번입니다. 같은 밀리초 안에서도 순서를 보장합니다. 참가자 단위 파일에서는 중간 번호가 비어 있을 수 있습니다(다른 참가자·세션 밖 이벤트).
- `payload`는 이벤트마다 내용이 다른 JSON 객체입니다(키 정렬).

| 이벤트 | 내용 |
|---|---|
| `app_launch`, `app_quit` | 앱 실행·종료 |
| `app_pause`, `app_resume` | 앱이 뒤로 감·앞으로 옴(`inactive`/`active`), Mac 잠자기·깨어남(`sleep`/`wake`) |
| `session_started` | 세션 시작: 조건, 종류, 학습 세트와 PDF별 SHA-256, 퀴즈 파일 정보, 통과 기준, 모델, 설정 스냅샷(API 키 제외), 설정 해시, 템플릿 지문 |
| `session_resumed` | 앱을 다시 열어 세션을 이어감: 꺼져 있던 시간, 지난번 정상 종료 여부 |
| `session_ended` | 세션 종료: 이유, 단계별 시간, 통과까지 걸린 시간, 체크포인트 응시 횟수 |
| `quiz_started`, `quiz_submitted` | 퀴즈 응시 시작·제출 (문제별 응답과 채점 결과) |
| `practice_difficulty_set` | 도구 조건의 연습 문제 난이도와 근거 |
| `problem_generated`, `problem_generation_failed` | 연습 문제 생성(문제 전문, LLM 원래 응답)과 검증 실패 |
| `problem_shown`, `problem_answered`, `problem_skipped` | 연습 문제 제시, 답안과 채점(빠진 요점 위치 포함), 넘기기 |
| `question_asked`, `answer_received` | 질문 원문, 답변(검색된 청크와 위치, 인용, LLM 원래 응답) |
| `hint_requested`, `hint_received` | 힌트 요청 단계, 받은 힌트 |
| `citation_opened` | 근거 위치 열기 |
| `document_opened`, `document_searched` | 자료 뷰어에서 문서 열기, 문서 안 찾기 |
| `llm_call` | LLM 요청 시도 하나: 작업, 모델, 시도 번호, 결과(success/retry/failure), 지연 시간, 상태 코드 |
| `error` | 앱 오류 |
| `log_exported` | 로그 내보내기: 범위, 파일 이름, zip SHA-256, 줄 수 |

## 여러 참가자 파일 합치기 (진행자)

Python(pandas) 예시:

```python
import glob, zipfile
import pandas as pd

sessions, items, events = [], [], []
for path in sorted(glob.glob("logs/pinpage-log_*.zip")):
    with zipfile.ZipFile(path) as z:
        sessions.append(pd.read_csv(z.open("sessions.csv"), encoding="utf-8-sig"))
        items.append(pd.read_csv(z.open("quiz_items.csv"), encoding="utf-8-sig"))
        events.append(pd.read_json(z.open("events.jsonl"), lines=True))

sessions = pd.concat(sessions, ignore_index=True)
# 같은 참가자를 여러 번 내보냈으면 가장 나중 파일만 남긴다
sessions = sessions.sort_values("exported_at").drop_duplicates("session_id", keep="last")
items = pd.concat(items, ignore_index=True).drop_duplicates(["session_id", "quiz_kind", "attempt_number", "question_id"])
```

확인할 것

- `quiz_sha256`과 `settings_hash`가 모든 참가자에게 같은지
- `app_version`, `model`이 같은지
- `unclean_exit_count`가 0이 아닌 세션 (강제 종료 뒤 이어서 진행함, 시간은 마지막 저장 시점부터 이어짐)
- `end_reason`이 `abandoned`나 `in_progress`인 세션
