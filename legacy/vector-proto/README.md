# reader vector search prototype

最小可跑的 BM25 + 向量 hybrid 检索原型，用来验证 vault 规模下向量召回是否
值得集成进 `reader-api`。**这是 prototype，不是生产代码。**

## 结论摘要

测试覆盖 BTS 综述真实场景下的查询类型：英文 / 中文 / 跨语言 / 自然语言问句 /
高频词 / 拼写错误。

| 场景 | BM25 表现 | 向量表现 | 是否值得上 |
|---|---|---|---|
| 跨语言同义词（`biopower` ↔ `生命权力`，`hermeneutics` ↔ `诠释学`）| 完全无法桥接 | 跨语言召回到位 | **必要** |
| 高频两字符（`AI`）| BM25 分数全部 ~0.15，排序近似随机 | cos 0.58-0.64 区分度好 | **必要** |
| 概念同义（`technology of the self` 召回到 `自我追踪技术 / 优化与增强的自我`）| 字面命中无关章节 | 语义召回准确 | **强烈推荐** |
| 自然语言问句（`数字技术如何重塑身体边界`）| 召回近乎乱猜 | 召回 `Digital Health` / `Materializing New Media` | **强烈推荐** |
| 拼写错误（`fucault`）| 0 命中 | 也救不了（多语言句嵌入对未知词无能为力） | 需另外的拼写纠正模块 |
| 词形（`phenomenology` ↔ `phenomenological`）| unicode61 不词干化，需精确词形 | 自然合并 | 锦上添花 |

## 架构

```
                          ┌─────────────────────┐
  query  ─────────────────▶ reader-api (Rust)   │
                          │  /api/search        │
                          │    │                │
                          │    ├── BM25 (FTS5)──┼── entry_search
                          │    │                │
                          │    └── vec sidecar──┼── vector-proto (Python)
                          │         │           │      vectors.npz
                          │   RRF fusion        │
                          │   k=60, weights …   │
                          └─────────┬───────────┘
                                    ▼
                              hybrid results
```

## 模型选择

* **`sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2`** (384 维, 220 MB)
* 选它是因为：CPU 跑得快、文件小、多语言覆盖广（~50 语言含中英）、跟
  reader 现规模匹配
* 全量 embed 13825 entries 在 M-series MacBook CPU 上 **5.7 分钟**（40 doc/s）
* 向量文件 `vectors.npz` 大约 20 MB（gzip 压缩 float32）

升级路径：质量不够时换 `bge-m3` (1024d, 2.3GB) 或 `multilingual-e5-large`，
模型替换不影响存储格式。

## 跑起来

```sh
cd vector-proto
python3 -m venv .venv
.venv/bin/pip install fastembed numpy

# 一次性 embed 全 vault（5-6 分钟）
.venv/bin/python embed_all.py

# 跑对比测试（需要 reader-api 在 5174 端口跑着）
.venv/bin/python query.py phenomenology biopower 生命权力
```

## 文件

* `embed_all.py` — 从 `<workspace>/.marple/index.sqlite` 读 entries，embed，存 `vectors.npz`
* `query.py` — Hybrid 查询脚本，并排打印 BM25 / vec / RRF 三种排序
* `vectors.npz` — 向量数据（不进 git）

## 下一步

如果决定集成到 reader-api：

1. **存储**：`vectors.npz` 改为 `index.sqlite` 里的 `entry_vectors` 表，用
   `sqlite-vec` crate (`cargo add sqlite-vec`) 加载 loadable extension，建
   `CREATE VIRTUAL TABLE entry_vectors USING vec0(path TEXT PRIMARY KEY,
   embedding float[384] distance_metric=cosine)`。`rusqlite` 在 Linux/macOS
   下用 `LoadExtension` API 加载（Apple 系统 Python 的限制不适用 Rust）。
2. **Query embedding**：Rust 端用 [`fastembed-rs`](https://github.com/Anush008/fastembed-rs)
   (`cargo add fastembed`)。**注意**：fastembed-rs 不带
   `paraphrase-multilingual-MiniLM-L12-v2`，但带 `multilingual-e5-small`
   （同样 384 维，且 e5 通常质量略好）—— 换模型 + 重新 embed 一次即可。
   E5 需要在 query 前加 `"query: "`、doc 前加 `"passage: "` 前缀。
3. **Chunking**：当前只 embed `title + author + themes + preview`（每 entry
   一向量）。下个里程碑切 body 成 ~512 token chunk 各自 embed，每 entry
   多向量、查询时 max-pool — 对长章节召回精度提升显著。
4. **Hybrid 端**：`search_entries` 加一路 vec 召回（top 30-50 candidates），
   和现有 BM25 / trigram / substring 候选用 RRF (k=60) 合并，替代当前的线
   性加权融合。
5. **拼写纠正层**：vec 救不了 `fucault` → `foucault`，需独立的字典纠错前
   置（候选：[`symspell`](https://crates.io/crates/symspell)，或简单的
   Levenshtein distance over 已知词典）。

## 已知短板

* **拼写错误**：向量召回也搞不定 `fucault` → `foucault`。需要独立的字典
  纠错（symspell / aspell / 编辑距离）作为查询预处理。
* **macOS 系统 Python**：Apple SQLite 编译时关了 extension 加载，所以
  prototype 不用 sqlite-vec，只用 numpy 暴力 top-k；集成到 Rust 端没这个
  限制。
