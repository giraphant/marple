#!/usr/bin/env python3
"""Render the original Notes research; no app or document-library access."""
from html import escape
import json
from pathlib import Path

root = Path(__file__).resolve().parent
data = json.loads((root / 'ulysses-notes-research.json').read_text())
e = escape
parts = ['<!doctype html><html lang="zh-CN"><meta charset="utf-8">',
         '<meta name="viewport" content="width=device-width,initial-scale=1">',
         f'<title>{e(data["title"])}</title>',
         '<style>body{max-width:960px;margin:48px auto;padding:0 24px;font:16px/1.8 system-ui;color:#243047;background:#fafbfc}h1,h2,h3{line-height:1.4}article{background:white;border:1px solid #dce3ec;border-radius:12px;padding:20px 24px;margin:18px 0}code{overflow-wrap:anywhere;font-size:13px}li{margin:8px 0}.summary{border-left:4px solid #4169a1;padding:12px 20px;background:#edf3fb}a{color:#245ca0}table{border-collapse:collapse;width:100%}th,td{text-align:left;padding:8px;border-bottom:1px solid #dce3ec}</style>',
         f'<h1>{e(data["title"])}</h1><p>{e(data["date"])} · Ulysses 42 (84473) · arm64</p>',
         f'<p class="summary">{e(data["summary"])}</p><p>{e(data["scope"])}</p>',
         '<p><a href="../ulysses-list/ulysses-list-research.html">此前的列表研究</a></p>']
implementation = data.get('implementation')
if implementation:
    parts.append(f'<h2>{e(implementation["title"])}</h2><p class="summary">{e(implementation["summary"])}</p><ul>')
    parts.extend(f'<li>{e(s)}</li>' for s in implementation['changes'])
    parts.append('</ul><table><caption>加载逻辑消融</caption><tr><th>方案</th><th>通过</th><th>失败</th></tr>')
    labels = {'baseline': '基线', 'without_read_sharing': '移除请求共享',
              'without_stale_result_guards': '移除过期结果检查',
              'without_draft_and_saved_baseline_preservation': '移除草稿与保存基线保护',
              'full_fix': '完整修复'}
    for row in implementation['loading_ablation']:
        parts.append(f'<tr><td>{e(labels[row["variant"]])}</td><td>{row["passed"]}</td><td>{row["failed"]}</td></tr>')
    parts.append(f'</table><p>{e(implementation["loading_interpretation"])}</p>')
    parts.append('<table><caption>布局消融：每批耗时（毫秒）</caption><tr><th>请求分布</th><th>基线</th><th>宽度缓存</th><th>异步合并</th></tr>')
    workloads = {'same_width_burst': '同一轮、相同宽度', 'four_widths_one_turn': '同一轮、四个宽度', 'one_width_per_turn': '分轮到达、四个宽度'}
    for row in implementation['layout_ablation']:
        parts.append(f'<tr><td>{e(workloads[row["workload"]])}</td><td>{row["baseline"]}</td><td>{row["width_guard"]}</td><td>{row["coalesced"]}</td></tr>')
    parts.append(f'</table><p>{e(implementation["layout_interpretation"])}</p><h3>未采用的方案</h3><ul>')
    parts.extend(f'<li>{e(s)}</li>' for s in implementation['not_adopted'])
    parts.append(f'</ul><p>{e(implementation["validation"])}</p><p>{e(implementation["delivery"])}</p><p>{e(implementation["open_source"])}</p>')
    parts.append('<details><summary>复现消融</summary><ul>')
    parts.extend(f'<li><code>{e(s)}</code></li>' for s in implementation['reproduction'])
    parts.append('</ul><p><a href="notes-loading-ablation.json">加载消融结果</a> · <a href="notes-layout-ablation.json">布局消融结果</a></p></details>')
comparison = data.get('comparison')
if comparison:
    parts.append(f'<h2>{e(comparison["title"])}</h2><p class="summary">{e(comparison["conclusion"])}</p><p>{e(comparison["method"])}</p>')
    parts.append('<table><caption>单次调用耗时（毫秒），每轮中位数的中位数</caption><tr><th>合成文本行数</th><th>无变化测高</th><th>原生布局与重复测高</th><th>宽度变化后测高</th><th>尾部追加字符后测高</th></tr>')
    for row in comparison['measurements']:
        cells = [str(row['lines'])] + [f'{row[key]:.4f}' for key in (
            'unchanged_remeasure', 'native_layout_then_remeasure',
            'width_change_then_remeasure', 'append_character_then_remeasure')]
        parts.append('<tr>' + ''.join(f'<td>{e(value)}</td>' for value in cells) + '</tr>')
    parts.append(f'</table><p>{e(comparison["interpretation"])}</p><p>{e(comparison["observation"])}</p>')
    for decision in comparison['decisions']:
        parts.append(f'<article><h3>{e(decision["priority"])} · {e(decision["topic"])}</h3>')
        for label, key in [('依据', 'evidence'), ('最小方向', 'change'), ('验收与边界', 'verify')]:
            parts.append(f'<p><strong>{label}：</strong>{e(decision[key])}</p>')
        parts.append('</article>')
    parts.append(f'<p>{e(comparison["oss"])}</p><ul>')
    parts.extend(f'<li>{e(s)}</li>' for s in comparison['limits'])
    parts.append('</ul><details><summary>复现独立实验</summary><ul>')
    parts.extend(f'<li><code>{e(s)}</code></li>' for s in comparison['reproduction'])
    parts.append('</ul><p><a href="notes-layout-measurements.json">三轮原始结果</a> · <a href="NotesLayoutProbe.swift">实验源码</a></p></details>')
parts.append('<h2>已核对的静态机制</h2>')
for f in data['findings']:
    parts.append(f'<article id="{e(f["id"])}"><h3>{e(f["id"])} · {e(f["title"])}</h3>')
    for label, key in [('观察', 'observed'), ('含义与边界', 'implication'), ('Marple 对照', 'marple')]:
        parts.append(f'<p><strong>{label}：</strong>{e(f[key])}</p>')
    parts.append('<details><summary>方法定位</summary><ul>')
    for ref in f['evidence']:
        parts.append(f'<li><code>{e(ref["image"])} {e(ref["address"])} [{e(ref["class_name"])} {e(ref["selector"])}]</code></li>')
    parts.append('</ul></details></article>')
parts.append('<h2>下一步验证顺序（尚未实施）</h2>')
for item in data['next_checks']:
    parts.append(f'<article><h3>{e(item["priority"])} · {e(item["title"])}</h3><p>{e(item["change"])}</p><p><strong>验收：</strong>{e(item["verify"])}</p></article>')
oss = data['open_source']
parts.append(f'<h2>开源对照</h2><p><a href="{e(oss["url"])}">{e(oss["name"])} · {e(oss["commit"][:7])}</a>：{e(oss["observation"])}</p>')
parts.append(f'<h2>Marple 源码定位</h2><p>审阅基线 <code>{e(data["marple_commit"])}</code></p><ul>')
for s in data['marple_sources']:
    url = f'https://github.com/giraphant/marple/blob/{data["marple_commit"]}/{s["path"]}#L{s["line"]}'
    parts.append(f'<li><a href="{e(url)}"><code>{e(s["path"])}:{s["line"]}</code></a> — {e(s["note"])}</li>')
parts.append('</ul><h2>验证边界</h2><ul>')
parts.extend(f'<li>{e(s)}</li>' for s in data['limits'])
parts.append('</ul><h2>复现</h2><ul>')
parts.extend(f'<li><code>{e(s)}</code></li>' for s in data['reproduction'])
parts.append('</ul>')
for name, binary in data['binary'].items():
    parts.append(f'<p>{e(name)} SHA-256：<code>{e(binary["sha256"])}</code></p>')
parts.append('</html>')
(root / 'ulysses-notes-research.html').write_text('\n'.join(parts) + '\n')
print(root / 'ulysses-notes-research.html')
