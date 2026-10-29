다음 자료로 연습 문제 하나를 만든다.

문제 유형: {{type}}
- multiple_choice: 서로 다른 보기 4개(choices)와 정답 번호(answer_index, 0부터). 오답 보기도 그럴듯하게 만든다.
- short_answer: 한두 단어로 답하는 문제. 인정할 정답들(accepted_answers)에 같은 뜻의 다른 표현도 넣는다.
- essay: 두세 문장으로 설명하는 문제. 모범 답안(model_answer)을 쓴다.

난이도: {{difficulty}}

같은 부분에서 이미 낸 문제 (겹치지 않게 한다):
{{avoid}}

자료:
{{sources}}

출력 형식: {"status": "ok" 또는 "insufficient", "question": "...", "choices": [...], "answer_index": 정수, "accepted_answers": [...], "model_answer": "...", "key_points": [{"point": "...", "source": 번호, "quote": "..."}]}
