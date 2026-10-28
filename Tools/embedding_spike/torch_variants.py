"""PyTorch로 기준값(CPU float32)과 GPU(MPS) 정밀도별 임베딩을 만든다.
usage: python torch_variants.py MODEL_DIR OUT_DIR
"""
import sys, time, glob, os
import numpy as np
import torch
from sentence_transformers import SentenceTransformer
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from corpus import PASSAGES, QUERIES, QUERY_PREFIX, doc_text

model_dir, out_dir = sys.argv[1], sys.argv[2]
os.makedirs(out_dir, exist_ok=True)
docs = [doc_text(t, x) for _, t, x in PASSAGES]
queries = [QUERY_PREFIX + q for q, _ in QUERIES]

variants = [
    ("torch_cpu_fp32", "cpu", torch.float32),
    ("torch_mps_fp32", "mps", torch.float32),
    ("torch_mps_fp16", "mps", torch.float16),
    ("torch_mps_bf16", "mps", torch.bfloat16),
]
for name, device, dtype in variants:
    model = SentenceTransformer(model_dir, device=device, model_kwargs={"dtype": dtype})
    # 이미지·음성 인코더는 쓰지 않는다. 텍스트만 넣는다.
    model.encode(["워밍업"], prompt="")
    t0 = time.perf_counter()
    d = model.encode(docs, prompt="", batch_size=16, normalize_embeddings=True, convert_to_numpy=True)
    t1 = time.perf_counter()
    q = model.encode(queries, prompt="", batch_size=16, normalize_embeddings=True, convert_to_numpy=True)
    t2 = time.perf_counter()
    single = []
    for text in queries[:10]:
        s = time.perf_counter(); model.encode([text], prompt=""); single.append(time.perf_counter() - s)
    np.savez(f"{out_dir}/{name}.npz", docs=d.astype(np.float32), queries=q.astype(np.float32),
             doc_sec=t1 - t0, query_sec=t2 - t1, single_ms=np.median(single) * 1000)
    print(f"{name}: docs {len(docs)}개 {t1-t0:.2f}s, 질문 1개 {np.median(single)*1000:.1f}ms, dim={d.shape[1]}", flush=True)
    del model
    if device == "mps":
        torch.mps.empty_cache()
