"""FluidInference Core ML 모델로 임베딩을 만든다 (Neural Engine / GPU / CPU).
usage: python coreml_run.py PKG_DIR OUT_DIR
"""
import sys, os, time, json
import numpy as np
import coremltools as ct
from tokenizers import Tokenizer
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from corpus import PASSAGES, QUERIES, QUERY_PREFIX, doc_text

pkg, out_dir = sys.argv[1], sys.argv[2]
cfg = json.load(open(f"{pkg}/config.json"))
tok = Tokenizer.from_file(f"{pkg}/tokenizer.json")
table = np.memmap(f"{pkg}/embeddings.bf16", dtype=np.uint16, mode="r", shape=(262144, 512))
SIZES = [32, 48, 64, 128, 256, 512]
scale = np.float32(cfg["embed_scale"])

def ids_for(text):
    ids = tok.encode(text, add_special_tokens=False).ids
    return [cfg["bos_token_id"]] + ids[:510] + [cfg["eos_token_id"]]

def inputs_for(ids):
    size = next(s for s in SIZES if s >= len(ids))
    rows = (table[ids].astype(np.uint32) << 16).view(np.float32) * scale
    emb = np.zeros((1, size, 512), dtype=np.float16)
    emb[0, :len(ids)] = rows.astype(np.float16)
    mask = np.zeros((1, size), dtype=np.float16)
    mask[0, :len(ids)] = 1
    return size, {"inputs_embeds": emb, "attention_mask": mask}

docs = [doc_text(t, x) for _, t, x in PASSAGES]
queries = [QUERY_PREFIX + q for q, _ in QUERIES]
lengths = [len(ids_for(t)) for t in docs + queries]
print(f"토큰 수: 최소 {min(lengths)}, 최대 {max(lengths)}, 평균 {np.mean(lengths):.0f}", flush=True)

for name, unit in [("coreml_ane", ct.ComputeUnit.CPU_AND_NE), ("coreml_gpu", ct.ComputeUnit.CPU_AND_GPU), ("coreml_cpu", ct.ComputeUnit.CPU_ONLY)]:
    models = {}
    t_load = time.perf_counter()
    def model_for(size):
        if size not in models:
            models[size] = ct.models.MLModel(f"{pkg}/EmbeddingGemma2Text.mlpackage", compute_units=unit, function_name=f"embed_{size}")
        return models[size]
    def embed(text):
        size, inp = inputs_for(ids_for(text))
        return np.asarray(model_for(size).predict(inp)["embedding"], dtype=np.float32).reshape(-1)
    for t in docs + queries:  # 필요한 함수를 모두 미리 불러오고 워밍업
        embed(t)
    load_sec = time.perf_counter() - t_load
    t0 = time.perf_counter(); d = np.stack([embed(t) for t in docs]); t1 = time.perf_counter()
    q = np.stack([embed(t) for t in queries])
    single = []
    for t in queries[:10]:
        s = time.perf_counter(); embed(t); single.append(time.perf_counter() - s)
    np.savez(f"{out_dir}/{name}.npz", docs=d, queries=q, doc_sec=t1 - t0, single_ms=np.median(single) * 1000)
    print(f"{name}: 첫 로드+워밍업 {load_sec:.1f}s (함수 {sorted(models)}), 문서 56개 {t1-t0:.2f}s, 질문 1개 {np.median(single)*1000:.1f}ms", flush=True)
