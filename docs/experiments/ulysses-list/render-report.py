#!/usr/bin/env python3
"""Render the original research summary; no binary or document-library access."""
from html import escape
import json
from pathlib import Path

root = Path(__file__).resolve().parent
data = json.loads((root / 'ulysses-list-research.json').read_text())
e = escape
parts = ['<!doctype html><html lang="zh-CN"><meta charset="utf-8">',
         '<meta name="viewport" content="width=device-width,initial-scale=1">',
         f'<title>{e(data["title"])}</title>',
         '<style>body{max-width:1060px;margin:48px auto;padding:0 24px;font:16px/1.8 system-ui;color:#243047;background:#fafbfc}h1,h2,h3{line-height:1.4}h1{font-size:30px}h2{margin-top:44px}article{background:white;border:1px solid #dce3ec;border-radius:12px;padding:20px 24px;margin:18px 0}code{overflow-wrap:anywhere;font-size:13px}li{margin:8px 0}.summary{border-left:4px solid #4169a1;padding:12px 20px;background:#edf3fb}.flow{display:flex;gap:10px;flex-wrap:wrap}.flow span{padding:10px 16px;background:#eaf0f7;border-radius:8px}small{color:#53647b}a{color:#245ca0}</style>',
         f'<h1>{e(data["title"])}</h1><p>{e(data["date"])} · Ulysses 42 (84473) · arm64</p>',
         f'<p class="summary">{e(data["summary"])}</p>',
         f'<p>{e(data["status"])}</p><p>{e(data["scope"])}</p>',
         '<div class="flow"><span>模型 / 搜索结果</span><span>→ 变更通知</span><span>→ 行身份与布局类型</span><span>→ 复用 cell</span><span>→ 合并文本更新</span></div>',
         '<p><small>概念关系图；具体同步、异步与后备分支见各项证据，不表示单一调用栈。</small></p>',
         '<h2>已核对的机制</h2>',
         '<p><small>F01–F10 的 Marple 对照为初次审阅基线；本轮修复与后续调查见下方进度。</small></p>']
for f in data['findings']:
    parts.append(f'<article id="{e(f["id"])}"><h3>{e(f["id"])} · {e(f["title"])}</h3>')
    for label, key in [('观察', 'observed'), ('含义与边界', 'implication'), ('Marple 对照', 'marple')]:
        parts.append(f'<p><strong>{label}：</strong>{e(f[key])}</p>')
    parts.append('<details><summary>方法定位</summary><ul>')
    for ref in f['evidence']:
        parts.append(f'<li><code>{e(ref["image"])} {e(ref["address"])} [{e(ref["class_name"])} {e(ref["selector"])}]</code></li>')
    parts.append('</ul></details></article>')
followup = data.get('followup')
if followup:
    parts.append('<h2>第二轮：最小修复与验证</h2><ul>')
    parts.extend(f'<li>{e(s)}</li>' for s in followup['implementation'])
    parts.append(f'</ul><p>{e(followup["validation"])}</p>')
    m = followup['measurement']
    parts.append(f'<p>{e(m["configuration"])}</p><p>{e(m["control"])}</p>')
    parts.append(f'<p class="summary">每轮最大心跳间隔的中位数：主 actor 对照 {m["control_max_gap_median_ms"]} ms → 后台计算 {m["background_max_gap_median_ms"]} ms。</p>')
    parts.append(f'<p>{e(m["interpretation"])}</p><p>基准：<code>{e(m["test"])}</code></p><ul>')
    parts.extend(f'<li>{e(s)}</li>' for s in followup['remaining'])
    parts.append('</ul>')
    if followup.get('runtime_observations'):
        parts.append('<h3>安装验证与待查问题</h3><ul>')
        parts.extend(f'<li>{e(s)}</li>' for s in followup['runtime_observations'])
        parts.append('</ul>')
parts.append('<h2>实施顺序与当前进度</h2>')
for item in data['proposed_work']:
    parts.append(f'<article><h3>{e(item["priority"])} · {e(item["title"])}</h3>')
    if 'status' in item:
        parts.append(f'<p><strong>{e(item["status"])}</strong></p>')
    for label, key in [('原因', 'reason'), ('最小改动', 'change'), ('验收', 'verify')]:
        parts.append(f'<p><strong>{label}：</strong>{e(item[key])}</p>')
    parts.append('</article>')
oss = data['open_source']
parts.append(f'<h2>开源对照</h2><p><a href="{e(oss["url"])}">FSNotes · {e(oss["commit"][:7])}</a>：{e(oss["observation"])}</p>')
parts.append(f'<h2>Marple 源码定位</h2><p>审阅基线 <code>{e(data["marple_commit"])}</code></p><ul>')
for s in data['marple_sources']:
    url = f'https://github.com/giraphant/marple/blob/{data["marple_commit"]}/{s["path"]}#L{s["line"]}'
    parts.append(f'<li><a href="{e(url)}"><code>{e(s["path"])}:{s["line"]}</code></a> — {e(s["note"])}</li>')
parts.append(f'</ul><h2>方法与验证边界</h2><p>{e(data["method"])}</p><p>{e(data["integration_tests"])}</p><ul>')
parts.extend(f'<li>{e(s)}</li>' for s in data['limits'])
parts.append('</ul><h2>复现</h2><ul>')
parts.extend(f'<li><code>{e(s)}</code></li>' for s in data['reproduction'])
parts.append('</ul>')
for image, digest in data['binary']['sha256'].items():
    parts.append(f'<p><small>{e(image)} SHA-256：<code>{e(digest)}</code></small></p>')
parts.append('</html>')
(root / 'ulysses-list-research.html').write_text('\n'.join(parts) + '\n')
print(root / 'ulysses-list-research.html')
