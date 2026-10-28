#!/usr/bin/env python3
"""앱이 처음 설정할 때 내려받을 임베딩 모델 폴더를 만든다 (표준 라이브러리만 사용).

FluidInference/embeddinggemma-2-coreml(고정 버전)에서 텍스트 임베딩에 필요한 파일만 골라
manifest.json(파일별 크기와 SHA-256)과 함께 OUT_DIR에 모은다. 이 폴더를 그대로 Hugging Face에 올린다.

예:
  python3 Tools/prepare_embedding_model.py dist/embedding-model
  python3 Tools/prepare_embedding_model.py dist/embedding-model --source-dir <이미 받은 폴더>
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
tags:
- coreml
- embeddings
---

# EmbeddingGemma 2 텍스트 임베딩 (Core ML) — Pinpage용

Pinpage 앱이 처음 설정할 때 내려받는 파일입니다. 내용은 바꾸지 않았고, 텍스트 임베딩에 필요한 파일만 골랐습니다.

- 원본 모델: [{BASE_MODEL}](https://huggingface.co/{BASE_MODEL}) (Apache 2.0)
- Core ML 변환: [{SOURCE_REPO}](https://huggingface.co/{SOURCE_REPO}) 버전 `{SOURCE_REVISION}` (Apache 2.0)
- `manifest.json`: 파일별 크기와 SHA-256. 앱은 내려받은 뒤 이 값으로 파일을 검증합니다.

사용법(입력 형식, 함수 목록)은 원본 Core ML 저장소의 README를 보세요.
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
    args = parser.parse_args()

    out = os.path.abspath(args.out_dir)
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
