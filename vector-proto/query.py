"""Hybrid search prototype: BM25 (via reader-api /api/search) + vector (npz).

For each query, fetches both ranked lists, merges with reciprocal rank
fusion, and prints a side-by-side comparison so we can see which
backend brought what to the table.
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.parse
import urllib.request
from pathlib import Path

import numpy as np
from fastembed import TextEmbedding


def load_vectors(path: Path):
    z = np.load(path, allow_pickle=False)
    return {
        "vectors": z["vectors"],
        "paths": z["paths"].tolist(),
        "types": z["types"].tolist(),
        "titles": z["titles"].tolist(),
        "model": str(z["model"][0]),
        "dim": int(z["dim"][0]),
    }


def fetch_bm25(query: str, limit: int = 30, host: str = "http://localhost:5174"):
    params = urllib.parse.urlencode({"q": query, "limit": limit})
    url = f"{host}/api/search?{params}"
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            payload = json.load(r)
    except Exception as exc:
        print(f"  warning: BM25 fetch failed: {exc}", file=sys.stderr)
        return []
    return [
        {
            "path": item["entry"]["path"],
            "type": item["entry"]["type"],
            "title": item["entry"].get("title") or item["entry"]["path"],
            "score": item.get("score", 0.0),
            "source": item.get("source", "?"),
        }
        for item in payload.get("items", [])
    ]


def vec_search(store, model: TextEmbedding, query: str, limit: int = 30):
    qvec = np.asarray(next(model.embed([query])), dtype=np.float32)
    n = np.linalg.norm(qvec)
    if n > 0:
        qvec = qvec / n
    sims = store["vectors"] @ qvec
    idx = np.argpartition(-sims, min(limit, len(sims) - 1))[:limit]
    idx = idx[np.argsort(-sims[idx])]
    out = []
    for i in idx:
        out.append(
            {
                "path": store["paths"][i],
                "type": store["types"][i],
                "title": store["titles"][i] or store["paths"][i],
                "score": float(sims[i]),
                "source": "vec",
            }
        )
    return out


def rrf(lists, weights=None, k: int = 60):
    weights = weights or [1.0] * len(lists)
    agg = {}
    for li, lst in enumerate(lists):
        w = weights[li]
        for rank, item in enumerate(lst):
            entry = agg.setdefault(
                item["path"],
                {
                    "path": item["path"],
                    "type": item["type"],
                    "title": item["title"],
                    "rrf": 0.0,
                    "ranks": {},
                },
            )
            entry["rrf"] += w / (k + rank + 1)
            entry["ranks"][li] = rank + 1
    return sorted(agg.values(), key=lambda x: -x["rrf"])


def fmt_row(label, item, idx):
    title = item["title"][:60]
    src = item.get("source", "")
    score = item.get("rrf", item.get("score"))
    return f"  {idx+1:>2}. [{item['type'][:6]:6}] {title:60}  {label}={score:.3f}"


def print_compare(query, bm25_hits, vec_hits, fused, top=10):
    print(f"\n==== query: {query!r} ====")
    print(f"  BM25 hits: {len(bm25_hits)}  Vec hits: {len(vec_hits)}  Fused: {len(fused)}")
    print("  --- BM25 top --- ")
    for i, h in enumerate(bm25_hits[:top]):
        print(fmt_row("bm25", h, i))
    print("  --- Vec top --- ")
    for i, h in enumerate(vec_hits[:top]):
        print(fmt_row("cos", h, i))
    print("  --- Hybrid (RRF) top --- ")
    for i, h in enumerate(fused[:top]):
        ranks = " ".join(f"{k}:{v}" for k, v in sorted(h["ranks"].items()))
        title = h["title"][:60]
        print(f"  {i+1:>2}. [{h['type'][:6]:6}] {title:60}  rrf={h['rrf']:.4f}  (ranks {ranks})")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--vectors",
        type=Path,
        default=Path(__file__).resolve().parent / "vectors.npz",
    )
    parser.add_argument("--limit", type=int, default=20)
    parser.add_argument("--show", type=int, default=8)
    parser.add_argument("queries", nargs="*")
    args = parser.parse_args()

    if not args.vectors.is_file():
        print(f"vectors not found: {args.vectors}", file=sys.stderr)
        sys.exit(1)
    store = load_vectors(args.vectors)
    print(f"loaded {len(store['paths'])} vectors (model={store['model']}, dim={store['dim']})", file=sys.stderr)

    model = TextEmbedding(model_name=store["model"])

    queries = args.queries or [
        "fucault",
        "phenomenology",
        "phenomenological",
        "hermeneutics",
        "诠释学",
        "biopower",
        "生命权力",
        "生命政治",
        "AI",
        "身体技术",
        "cyborg",
        "数字技术如何重塑身体边界",
        "technology of the self",
    ]

    for q in queries:
        bm25 = fetch_bm25(q, limit=args.limit)
        vec = vec_search(store, model, q, limit=args.limit)
        fused = rrf([bm25, vec], weights=[1.0, 1.0])
        print_compare(q, bm25, vec, fused, top=args.show)


if __name__ == "__main__":
    main()
