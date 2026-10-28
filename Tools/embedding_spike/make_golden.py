"""Swift 구현을 검증할 기준값(토큰 ID, 임베딩 벡터)을 만든다.
기준값: tokenizers(add_special_tokens=False)의 토큰 ID, sentence-transformers CPU float32 벡터.

usage: python make_golden.py ORIGINAL_MODEL_DIR TOKENIZER_JSON OUT_JSON
"""
import json, sys
import torch
from tokenizers import Tokenizer
from sentence_transformers import SentenceTransformer

model_dir, tokenizer_json, out = sys.argv[1:4]

TEXTS = [
    "task: search result | query: 리스트와 튜플의 차이가 뭐야?",
    "title: 자료형 | text: 튜플은 리스트와 비슷하지만 한 번 만들면 원소를 바꿀 수 없는 불변 자료형이다.",
    "title: none | text: def fib(n):\n    if n < 2:\n\t\treturn n\n    return fib(n - 1) + fib(n - 2)",
    "task: search result | query: 한글 파일 읽을 때 UnicodeDecodeError가 나 😢",
    "title: none | text: The quick brown fox jumps over the lazy dog. 3.14159, x_y = {'a': [1, 2]}",
    "  앞뒤에   공백이  여러 개   있는 문장  ",
    "title: 운영체제 | text: " + "교착 상태는 둘 이상의 프로세스가 서로 상대가 가진 자원을 기다리며 영원히 멈춘 상태다. " * 12,
    "ㄱㄴㄷ ㅏㅑ 漢字 ﬁ ① ½ — “따옴표” ‘작은’ …",
]

tok = Tokenizer.from_file(tokenizer_json)
model = SentenceTransformer(model_dir, device="cpu", model_kwargs={"dtype": torch.float32})
vectors = model.encode(TEXTS, prompt="", normalize_embeddings=True, convert_to_numpy=True)

cases = []
for text, vec in zip(TEXTS, vectors):
    ids = tok.encode(text, add_special_tokens=False).ids
    cases.append({"text": text, "ids": ids, "vector": [round(float(v), 7) for v in vec]})
    print(len(ids), "tokens:", text[:40].replace("\n", " "))

json.dump({"source": "sentence-transformers CPU float32, tokenizers add_special_tokens=False", "cases": cases},
          open(out, "w"), ensure_ascii=False)
print("saved", out)
