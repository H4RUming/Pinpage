다음 자료로 사전 퀴즈 문제 하나를 만든다.

문제 유형: {{type}}
- multiple_choice: 서로 다른 보기 4개(choices)와 정답 번호(answer_index, 0부터). 정답은 하나뿐이어야 하고, 오답 보기도 그럴듯하게 만든다.
- short_answer: 용어나 숫자 하나로 답하는 문제. 채점은 공백·대소문자·문장부호만 무시하고 글자를 그대로 비교하므로, 인정할 정답들(accepted_answers)에 한글 표기, 영어 표기, 약어처럼 같은 답의 다른 표기를 모두 넣는다.

난이도: {{difficulty}}

이미 낸 문제 (겹치지 않게 한다):
{{avoid}}

자료:
{{sources}}

출력 형식: {"status": "ok" 또는 "insufficient", "question": "...", "choices": [...], "answer_index": 정수, "accepted_answers": [...], "model_answer": "...", "key_points": [{"point": "...", "source": 번호, "quote": "..."}]}
