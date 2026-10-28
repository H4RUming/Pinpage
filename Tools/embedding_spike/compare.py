"""기준값(torch_cpu_fp32)과 각 방식의 임베딩을 비교한다.
usage: python compare.py OUT_DIR
"""
import sys, glob, os
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from corpus import PASSAGES, QUERIES

K = 5
ids = [p[0] for p in PASSAGES]
out = sys.argv[1]

def load(name):
    z = np.load(f"{out}/{name}.npz")
    norm = lambda m: m / np.linalg.norm(m, axis=1, keepdims=True)
    return norm(z["docs"]), norm(z["queries"]), z

def topk(d, q):
    scores = q @ d.T
    return np.argsort(-scores, axis=1)[:, :K], scores

ref_d, ref_q, _ = load("torch_cpu_fp32")
ref_top, ref_scores = topk(ref_d, ref_q)

def quality(top):
    hit = np.mean([any(ids[i] in gold for i in top[n]) for n, (_, gold) in enumerate(QUERIES)])
    rec = np.mean([len({ids[i] for i in top[n]} & set(gold)) / len(gold) for n, (_, gold) in enumerate(QUERIES)])
    return hit, rec

rows = []
for path in sorted(glob.glob(f"{out}/*.npz")):
    name = os.path.basename(path)[:-4]
    d, q, z = load(name)
    if d.shape[1] != ref_d.shape[1]:
        print(f"{name}: 차원이 다름 {d.shape}")
        continue
    cos = np.concatenate([np.sum(d * ref_d, axis=1), np.sum(q * ref_q, axis=1)])
    top, scores = topk(d, q)
    overlap = np.mean([len(set(top[n]) & set(ref_top[n])) / K for n in range(len(QUERIES))])
    same_order = np.mean([list(top[n]) == list(ref_top[n]) for n in range(len(QUERIES))])
    top1 = np.mean(top[:, 0] == ref_top[:, 0])
    score_diff = np.max(np.abs(scores - ref_scores))
    hit, rec = quality(top)
    rows.append((name, cos.min(), cos.mean(), overlap, same_order, top1, score_diff, hit, rec,
                 float(z["doc_sec"]) if "doc_sec" in z else float("nan"),
                 float(z["single_ms"]) if "single_ms" in z else float("nan")))

print(f"{'방식':<24}{'최소cos':>9}{'평균cos':>10}{'top5겹침':>9}{'순서동일':>9}{'top1동일':>9}{'점수차max':>10}{'hit@5':>7}{'recall@5':>9}{'문서56개s':>10}{'질문1개ms':>10}")
for r in rows:
    print(f"{r[0]:<24}{r[1]:>9.5f}{r[2]:>10.6f}{r[3]:>9.1%}{r[4]:>9.1%}{r[5]:>9.1%}{r[6]:>10.5f}{r[7]:>7.0%}{r[8]:>9.0%}{r[9]:>10.2f}{r[10]:>10.1f}")

# 기준값과 순위가 다른 질문은 어떻게 다른지 보여준다.
for path in sorted(glob.glob(f"{out}/*.npz")):
    name = os.path.basename(path)[:-4]
    if name == "torch_cpu_fp32":
        continue
    d, q, _ = load(name)
    if d.shape[1] != ref_d.shape[1]:
        continue
    top, scores = topk(d, q)
    for n in range(len(QUERIES)):
        if list(top[n]) != list(ref_top[n]):
            gap = ref_scores[n, ref_top[n][K-1]] - ref_scores[n, np.argsort(-ref_scores[n])[K]]
            print(f"  [{name}] '{QUERIES[n][0]}': 기준 {[ids[i] for i in ref_top[n]]} / 비교 {[ids[i] for i in top[n]]} (기준 5·6위 점수차 {gap:.4f})")
