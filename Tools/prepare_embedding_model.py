#!/usr/bin/env python3
"""앱이 처음 설정할 때 내려받을 임베딩 모델 폴더를 만든다 (표준 라이브러리만 사용).

FluidInference/embeddinggemma-2-coreml(고정 버전)에서 텍스트 임베딩에 필요한 파일만 골라
manifest.json(파일별 크기와 SHA-256)과 함께 OUT_DIR에 모은다. 이 폴더를 그대로 Hugging Face에 올린다.

예:
  python3 Tools/prepare_embedding_model.py dist/embedding-model
  python3 Tools/prepare_embedding_model.py dist/embedding-model --source-dir <이미 받은 폴더>
  python3 Tools/prepare_embedding_model.py dist/embedding-model --readme-only
"""
import argparse
import hashlib
import json
import os
import shutil
import sys
import urllib.request

SOURCE_REPO = "FluidInference/embeddinggemma-2-coreml"
SOURCE_REVISION = "3f978ddf92cac9aa07eb2dcf6eb36cf450f3dba4"
BASE_MODEL = "google/embeddinggemma-2"

# 텍스트 임베딩에 필요한 파일. 음성·이미지 인코더는 넣지 않는다.
FILES = [
    "EmbeddingGemma2Text.mlpackage/Manifest.json",
    "EmbeddingGemma2Text.mlpackage/Data/com.apple.CoreML/model.mlmodel",
    "EmbeddingGemma2Text.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
    "embeddings.bf16",
    "tokenizer.json",
    "config.json",
]

README = f"""---
license: apache-2.0
base_model: {BASE_MODEL}
library_name: coreml
pipeline_tag: feature-extraction
language:
- ko
- multilingual
tags:
- coreml
- embeddings
- apple-silicon
---

# EmbeddingGemma 2 텍스트 임베딩 (Core ML) — Pinpage용

Pinpage(macOS 학습 앱)가 처음 설정할 때 내려받는 임베딩 모델입니다.
파일 내용은 원본과 같고, 텍스트 임베딩에 필요한 파일만 골랐습니다(음성·이미지 인코더 제외).

- 원본 모델: [{BASE_MODEL}](https://huggingface.co/{BASE_MODEL}) (Apache 2.0)
- Core ML 변환: [{SOURCE_REPO}](https://huggingface.co/{SOURCE_REPO}) 버전 `{SOURCE_REVISION}` (Apache 2.0)
- 출력: 768차원, L2 정규화 벡터 (512·256·128차원으로 잘라 다시 정규화해서 쓸 수 있음)
- 요구 사항: macOS 15 이상 (여러 함수를 담은 Core ML 모델)

## 파일

| 파일 | 크기 | 내용 |
|---|---|---|
| `EmbeddingGemma2Text.mlpackage/` | 284 MB | Core ML 텍스트 모델 (fp16, 입력 길이별 함수 `embed_32`~`embed_512`, `pack_256`) |
| `embeddings.bf16` | 268 MB | 토큰 임베딩 표 262,144 × 512 (bfloat16). 행을 읽어 √512를 곱해 입력으로 넣는다 |
| `tokenizer.json` | 32 MB | 원본 Gemma 토크나이저 |
| `config.json` | 3 KB | 함수 목록, 토큰 ID, 작업 프롬프트 |
| `manifest.json` | 1 KB | 파일별 크기와 SHA-256. 앱은 내려받은 뒤 이 값으로 검증한다 |

입력 형식과 함수 사용법은 원본 Core ML 저장소의 README를 보세요.

## 검증 결과 (2026-10-28, Apple M2 24GB, macOS 27.0.1)

PyTorch CPU float32(sentence-transformers) 결과를 기준값으로 두고, 같은 입력을 여러 방식으로 임베딩해 비교했습니다.

**테스트 자료:** 한국어 강의 자료풍 문단 48개 + 파이썬 코드 조각 8개, 정답이 정해진 한국어 질문 24개.
순위가 쉽게 바뀌도록 비슷한 주제의 문단을 일부러 섞었고, 일부 질문은 문단과 코드가 둘 다 정답입니다.
질문 앞에는 `task: search result | query: `, 문서 앞에는 `title: {{제목}} | text: `를 붙였습니다.

| 방식 | 최소 코사인 | 상위 5개 겹침 | 상위 5개 순서 동일 | 1위 동일 | hit@5 | recall@5 | 문서 56개 | 질문 1개 |
|---|---|---|---|---|---|---|---|---|
| PyTorch CPU fp32 (기준값) | 1.00000 | 100% | 100% | 100% | 100% | 90% | 2.39 s | 61.8 ms |
| **Core ML GPU** | **1.00000** | **100%** | **100%** | **100%** | 100% | 90% | 1.09 s | 14.7 ms |
| Core ML Neural Engine | 0.99988 | 97.5% | 87.5% | 100% | 100% | 90% | **0.39 s** | **5.2 ms** |
| Core ML CPU | 0.99984 | 100% | 100% | 100% | 100% | 90% | 1.11 s | 10.9 ms |
| PyTorch GPU (MPS) fp16 | 1.00000 | 100% | 100% | 100% | 100% | 90% | 2.17 s | 42.2 ms |
| PyTorch GPU (MPS) bf16 | 0.99990 | 96.7% | 79.2% | 95.8% | 100% | 90% | 3.26 s | 44.5 ms |

- **한국어 검색:** 24개 질문 모두 정답이 상위 5개 안에 들었고(hit@5 100%), 정답 근거의 90%를 찾았습니다.
- **Core ML GPU:** 기준값과 벡터와 순위가 같습니다. Pinpage는 실험 참가자 간 일관성을 위해 이 방식을 기본으로 씁니다.
- **Core ML Neural Engine:** 24개 중 3개 질문에서 5위만 바뀌었습니다. 세 경우 모두 기준값의 5·6위 점수 차이가 0.0005 이하인 사실상 동점이었고, 1위와 정답 근거는 바뀌지 않았습니다.
- **첫 로드:** 기기에서 처음 불러올 때 Core ML 컴파일이 필요합니다(M2에서 Neural Engine 약 70초, GPU 약 45초). 결과는 Core ML이 캐시합니다.

**한계:** 기기 한 대(M2)와 작은 합성 자료로 잰 결과입니다. 다른 칩(M3 등)과 실제 강의 자료에서는 따로 확인이 필요합니다.
측정 스크립트는 Pinpage 저장소의 `Tools/embedding_spike/`에 있습니다.
"""


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def download(rel, dest):
    url = f"https://huggingface.co/{SOURCE_REPO}/resolve/{SOURCE_REVISION}/{rel}"
    print(f"내려받는 중: {rel}", flush=True)
    with urllib.request.urlopen(url) as response, open(dest, "wb") as out:
        shutil.copyfileobj(response, out, 1 << 20)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out_dir")
    parser.add_argument("--source-dir", help="원본 저장소를 이미 받아 둔 폴더 (없으면 내려받는다)")
    parser.add_argument("--readme-only", action="store_true", help="이미 만든 폴더의 README.md만 다시 쓴다")
    args = parser.parse_args()

    out = os.path.abspath(args.out_dir)
    if args.readme_only:
        with open(os.path.join(out, "README.md"), "w") as f:
            f.write(README)
        print(f"README.md를 다시 썼습니다: {out}")
        return
    if os.path.exists(out):
        sys.exit(f"{out}이(가) 이미 있습니다. 지우고 다시 실행하세요.")

    entries = []
    for rel in FILES:
        dest = os.path.join(out, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        if args.source_dir:
            shutil.copyfile(os.path.join(args.source_dir, rel), dest)  # 심볼릭 링크는 실제 내용으로 복사된다
        else:
            download(rel, dest)
        entries.append({"path": rel, "size": os.path.getsize(dest), "sha256": sha256_of(dest)})

    manifest = {
        "format": "pinpage-embedding-model",
        "formatVersion": 1,
        "baseModel": BASE_MODEL,
        "source": {"repo": SOURCE_REPO, "revision": SOURCE_REVISION},
        "files": entries,
    }
    with open(os.path.join(out, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
    with open(os.path.join(out, "README.md"), "w") as f:
        f.write(README)

    total = sum(e["size"] for e in entries)
    print(f"완료: {out} (파일 {len(entries)}개, {total / 1e6:.0f} MB)")


if __name__ == "__main__":
    main()
