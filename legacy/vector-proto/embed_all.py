"""Embed every entry in reader/data/index.sqlite into a vector store.

One row per entry. Text = title + author + themes + preview. This is the
prototype scope — chunking entire bodies comes later.

Output: reader/vector-proto/vectors.db with a sqlite-vec vec0 table.
"""
from __future__ import annotations

import argparse
import sqlite3
import sys
import time
from pathlib import Path

import json

import numpy as np
from fastembed import TextEmbedding


def open_index_db(path: Path) -> sqlite3.Connection:
    con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    return con


def fetch_entries(con: sqlite3.Connection):
    cur = con.execute(
        """
        SELECT
          e.path,
          e.type,
          e.title,
          e.author,
          e.book,
          e.preview,
          (SELECT GROUP_CONCAT(theme, ' ') FROM entry_themes t WHERE t.path = e.path) AS themes
        FROM entries e
        """
    )
    for row in cur:
        path, etype, title, author, book, preview, themes = row
        text_parts = [title or "", author or "", book or "", themes or "", preview or ""]
        text = "\n".join(p for p in text_parts if p).strip()
        yield path, etype, title, text


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--index",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "data" / "index.sqlite",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=Path(__file__).resolve().parent / "vectors.npz",
    )
    parser.add_argument(
        "--model",
        default="sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2",
    )
    parser.add_argument("--batch", type=int, default=64)
    parser.add_argument("--limit", type=int, default=0, help="0 = all")
    args = parser.parse_args()

    if not args.index.is_file():
        print(f"index not found: {args.index}", file=sys.stderr)
        sys.exit(1)

    print(f"loading model {args.model} ...", file=sys.stderr)
    model = TextEmbedding(model_name=args.model)
    dim = len(next(model.embed(["probe"])))
    print(f"  dim = {dim}", file=sys.stderr)

    con_src = open_index_db(args.index)
    rows = list(fetch_entries(con_src))
    con_src.close()
    if args.limit:
        rows = rows[: args.limit]
    print(f"  entries = {len(rows)}", file=sys.stderr)

    paths = []
    types = []
    titles = []
    texts_kept = []
    vecs_all = np.zeros((len(rows), dim), dtype=np.float32)

    t0 = time.perf_counter()
    n = 0
    for start in range(0, len(rows), args.batch):
        chunk = rows[start : start + args.batch]
        texts = [r[3] or r[2] or r[0] for r in chunk]
        vecs = list(model.embed(texts, batch_size=args.batch))
        for i, ((path, etype, title, text), vec) in enumerate(zip(chunk, vecs)):
            arr = np.asarray(vec, dtype=np.float32)
            # normalize for cosine = dot
            norm = np.linalg.norm(arr)
            if norm > 0:
                arr = arr / norm
            vecs_all[start + i] = arr
            paths.append(path)
            types.append(etype)
            titles.append(title or "")
            texts_kept.append(text or "")
        n += len(chunk)
        dt = time.perf_counter() - t0
        rate = n / dt if dt > 0 else 0
        eta = (len(rows) - n) / rate if rate > 0 else 0
        print(f"  {n}/{len(rows)}  {rate:.1f}/s  eta {eta:.0f}s", file=sys.stderr)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(
        args.out,
        vectors=vecs_all,
        paths=np.array(paths),
        types=np.array(types),
        titles=np.array(titles),
        model=np.array([args.model]),
        dim=np.array([dim]),
    )
    print(
        f"wrote {args.out} ({args.out.stat().st_size/1e6:.1f} MB) in {time.perf_counter()-t0:.1f}s",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
