import { useEffect, useRef } from 'preact/hooks';
import { EditorView, keymap, drawSelection, Decoration, ViewPlugin } from '@codemirror/view';
import type { DecorationSet, ViewUpdate } from '@codemirror/view';
import type { Extension } from '@codemirror/state';
import { EditorState, Compartment, RangeSetBuilder } from '@codemirror/state';
import { defaultKeymap, history, historyKeymap, indentWithTab } from '@codemirror/commands';
import { markdown } from '@codemirror/lang-markdown';
import { HighlightStyle, syntaxHighlighting } from '@codemirror/language';
import { tags as t } from '@lezer/highlight';
export interface EditorThemeConfig {
  /** Resolved 'light' | 'dark' (not 'system'). Drives editor color scheme.
   * Font family / size / line-height are NOT props — they flow in via the
   * global --reader-font-* CSS vars set by app.tsx, so font tweaks don't
   * rebuild the editor (caret / undo / scroll are preserved). */
  dark: boolean;
}

// Editor color palettes — ported from Ulysses Blush theme.
// 与 styles.css 的 --reader-* 同源；保持编辑器与阅读模式视觉一致。
const PALETTE = {
  light: {
    bg:       '#f5f5f5',  /* Blush bg, matches --bg-page */
    fg:       '#444444',  /* Blush fg */
    fgHi:     '#000000',
    fgMed:    '#737373',
    caret:    '#ff5f8b',  /* 粉色 caret — Blush 标志色 */
    selection:'#fce4ec',  /* 浅粉 selection */
    markup:   '#bfbfbf',  /* markup 字符（*、>、# 等）— 比正文淡 */
    hr:       '#d4d4d4',
    /* 语义色 — 直接拷自 styles.css --reader-* */
    heading:  '#fa9600',
    strong:   '#9d6ad8',
    em:       '#ff5f8b',
    quote:    '#bd693f',
    quoteLineBg: '#f5ebe2',  /* 浅桃色 — blockquote 整行 bg */
    code:     '#bd693f',
    codeBg:   '#f0eae6',
    link:     '#f66b00',
    marker:   '#9d6ad8',
  },
  dark: {
    bg:       '#2a2229',  /* Blush dark bg */
    fg:       '#ecddd9',  /* Blush dark fg */
    fgHi:     '#ffffff',
    fgMed:    '#c3b2ad',
    caret:    '#ff4771',
    selection:'#5a2638',
    markup:   '#6b5a66',
    hr:       '#5f525d',
    heading:  '#eeb500',
    strong:   '#ac81f3',
    em:       '#ff4771',
    quote:    '#ecddd9',
    quoteLineBg: '#3c3037',  /* 比 page bg 略亮的酒红 wash */
    code:     '#00c372',
    codeBg:   '#362c34',
    link:     '#0097de',
    marker:   '#ecddd9',
  },
} as const;

interface Props {
  /** Stable identifier; reinit the editor when this changes (entry switch). */
  docId: string;
  /** Initial body text. We never re-seed after mount unless `docId` changes. */
  initial: string;
  theme: EditorThemeConfig;
  onChange: (body: string) => void;
  onSaveShortcut?: () => void;
}

// Ulysses-flavored markdown highlight: markers stay visible but are muted, the
// content they wrap is what stands out. No WYSIWYG, no preview pane.
const highlightStyle = HighlightStyle.define([
  { tag: t.heading1, class: 'cm-h1' },
  { tag: t.heading2, class: 'cm-h2' },
  { tag: t.heading3, class: 'cm-h3' },
  { tag: t.heading4, class: 'cm-h4' },
  { tag: t.heading5, class: 'cm-h5' },
  { tag: t.heading6, class: 'cm-h6' },
  { tag: t.strong, class: 'cm-strong' },
  { tag: t.emphasis, class: 'cm-em' },
  { tag: t.monospace, class: 'cm-code' },
  { tag: t.url, class: 'cm-url' },
  { tag: t.link, class: 'cm-link' },
  { tag: t.quote, class: 'cm-quote' },
  { tag: t.list, class: 'cm-list' },
  { tag: t.processingInstruction, class: 'cm-markup' },
  { tag: t.contentSeparator, class: 'cm-hr' },
  { tag: t.atom, class: 'cm-markup' },
  { tag: t.meta, class: 'cm-markup' },
]);

// 单一 line-decoration plugin：复刻 Ulysses 的两个排版机制 —
//  (1) hanging indent — markdown markers (# ## - * > 1.) 挂到正文左侧 margin，
//      正文文字在每一行同一列起始，不会因 H1/H2/list 而左右抖动。
//      做法：对 marker 行 emit `text-indent: -${markerLen}ch`；cm-line 的
//      padding-left 给出 marker 挂位。
//  (2) blockquote 整行 bg — `>` 开头的行加 `cm-blockquote-line` class 触发 bg。
//      不按 syntaxTree 的 Blockquote 节点范围（CommonMark 的 lazy continuation
//      会把两个 `>` 之间的 plain 行吞进去）。Ulysses Markdown XL 是逐行判断。
//
// MARKER_RE 捕获：(leading-ws)(marker-chars)(trailing-ws)。
// 计算 text-indent 时用 marker+trailing-ws 的字符数 —— 让 marker 后第一个
// 实际正文字符落到非 marker 行同列。
const MARKER_RE = /^(\s*)(#{1,6}|[-*+]|\d{1,3}[.)]|>)(\s+)/;
const LIST_MARKER_RE = /^[-*+]|^\d/;

function computeMarkerDeco(view: EditorView): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  for (const { from, to } of view.visibleRanges) {
    let pos = from;
    while (pos <= to) {
      const line = view.state.doc.lineAt(pos);
      const m = line.text.match(MARKER_RE);
      if (m) {
        const leadingSpaces = m[1].length;
        const marker = m[2];
        const hangLen = marker.length + m[3].length;
        const isQuote = marker === '>';
        const isList = LIST_MARKER_RE.test(marker);

        let style: string;
        if (isList) {
          // List: marker 与 body column 同列，content 后退 2em (≈ 2 全角字符) —
          // 复刻 Ulysses 的 list 排版：marker 短小、与正文左对齐，content
          // 明显往右一档。nested 每多 2 leading spaces 加 2em 整体缩进。
          const nestedLevel = Math.floor(leadingSpaces / 2);
          const padEm = 5 + nestedLevel * 2;
          style = `padding-left: ${padEm}em; text-indent: -2em`;
        } else {
          // heading / blockquote: marker 挂在 padding gutter 里，content 在 body column。
          // hangLen = marker 字符数 + trailing space，用 ch 让对齐到 body 段落同列。
          style = `text-indent: -${hangLen}ch`;
        }

        const dec = isQuote
          ? Decoration.line({ class: 'cm-blockquote-line', attributes: { style } })
          : Decoration.line({ attributes: { style } });
        builder.add(line.from, line.from, dec);
      }
      if (line.to + 1 > view.state.doc.length) break;
      pos = line.to + 1;
    }
  }
  return builder.finish();
}

const markerLineDecorations = ViewPlugin.fromClass(class {
  decorations: DecorationSet;
  constructor(view: EditorView) { this.decorations = computeMarkerDeco(view); }
  update(u: ViewUpdate) {
    if (u.docChanged || u.viewportChanged) {
      this.decorations = computeMarkerDeco(u.view);
    }
  }
}, { decorations: v => v.decorations });

// Build the editor theme from settings — caller-controlled font, size, leading;
// rest of the visual language (off-white page, muted markers, warm caret) is
// constant and matches Ulysses sensibility.
function buildEditorTheme({ dark }: EditorThemeConfig): Extension {
  const p = dark ? PALETTE.dark : PALETTE.light;
  return EditorView.theme({
    '&': {
      height: '100%',
      backgroundColor: p.bg,
      color: p.fg,
    },
    '&.cm-focused': { outline: 'none' },
    '.cm-scroller': {
      fontFamily: 'var(--reader-font-family)',
      fontSize: 'var(--reader-font-size)',
      lineHeight: 'var(--reader-line-height)',
      padding: '8px 0',
    },
    '.cm-content': {
      maxWidth: '680px',
      margin: '0 auto',
      padding: '48px 8px 60vh 8px',
      caretColor: p.caret,
      // CJK ↔ Latin 之间自动半字宽（Chrome/Safari ≥ 2024 起支持）。
      // 让「技术物 X」「环境 E」之类自然出现间隔，不靠手动空格。
      textSpacingTrim: 'space-all' as never,
    },
    // padding-left 3em：给 markdown markers 留挂位 —— marker lines 加
    // text-indent:-Xch 后 marker 落到本 padding 范围内，正文文字落在 3em 开始处
    // 与所有 plain 行同列。padding-right 1.5em 给右侧呼吸感、避免文字贴边。
    '.cm-line': { paddingLeft: '3em', paddingRight: '1.5em' },
    '.cm-cursor': { borderLeftWidth: '1px', borderLeftColor: p.caret },
    '&.cm-focused .cm-selectionBackground, ::selection': { backgroundColor: `${p.selection} !important` },

    // Blush 风：编辑器里所有标题等字号 = body（写作视觉稳定，不会 H1→H4 塌缩字号）；
    // 仅靠颜色 + weight 渐变区分级别。Theme.xml 只写了 bold / non-bold 二值，
    // 但 Ulysses 实测有 H1→H5 渐变，是 app 内置行为；这里复刻成阶梯 weight。
    // 阅读模式 .prose-body h* 仍保持字号层级用于真实阅读。
    '.cm-h1': { fontSize: '1em', fontWeight: '800', color: p.heading },
    '.cm-h2': { fontSize: '1em', fontWeight: '700', color: p.heading },
    '.cm-h3': { fontSize: '1em', fontWeight: '600', color: p.heading },
    '.cm-h4': { fontSize: '1em', fontWeight: '500', color: p.heading },
    '.cm-h5': { fontSize: '1em', fontWeight: '400', color: p.heading },
    '.cm-h6': { fontSize: '1em', fontWeight: '300', color: p.heading },

    '.cm-strong': { fontWeight: '700', color: p.strong },
    // emph: 粉色 + italic — CJK glyph 自然 fallback 成普通字重的彩色文本，
    // 西文 glyph 出真 italic。两端都能识别。
    '.cm-em': { color: p.em, fontStyle: 'italic' },
    '.cm-code': {
      fontFamily: 'ui-monospace, "SF Mono", SFMono-Regular, "JetBrains Mono", monospace',
      backgroundColor: p.codeBg,
      color: p.code,
      padding: '0 4px',
      borderRadius: '3px',
      fontSize: '0.9em',
    },

    '.cm-markup': { color: p.markup },
    // list marker (- / * / 1.) 在 Blush 里是紫色 + bold。
    '.cm-list':   { color: p.marker, fontWeight: '700' },
    // hr 用粉色 — Ulysses Blush 里 `---` 是粉色横线。
    '.cm-hr':     { color: p.em },

    // blockquote 文字不加 italic — CJK 整段伪斜体丑。
    // 整行 bg 高亮由下面 blockquoteLineHighlight extension 负责（line decoration）。
    '.cm-quote': { color: p.quote },
    '.cm-blockquote-line': { backgroundColor: p.quoteLineBg },

    '.cm-link': { color: p.link, fontWeight: '700' },
    '.cm-url':  { color: p.link, textDecoration: 'underline' },
  });
}

const editableCompartment = new Compartment();
const themeCompartment = new Compartment();

export function NoteEditor({ docId, initial, theme, onChange, onSaveShortcut }: Props) {
  const hostRef = useRef<HTMLDivElement>(null);
  const viewRef = useRef<EditorView | null>(null);
  const onChangeRef = useRef(onChange);
  const onSaveRef = useRef(onSaveShortcut);
  onChangeRef.current = onChange;
  onSaveRef.current = onSaveShortcut;

  // Rebuild the editor only when docId changes — otherwise updates would clobber
  // the user's caret / selection / history.
  useEffect(() => {
    if (!hostRef.current) return;

    const saveKeymap = keymap.of([
      {
        key: 'Mod-s',
        preventDefault: true,
        run: () => { onSaveRef.current?.(); return true; },
      },
    ]);

    const state = EditorState.create({
      doc: initial,
      extensions: [
        history(),
        drawSelection(),
        markdown(),
        syntaxHighlighting(highlightStyle),
        markerLineDecorations,
        EditorView.lineWrapping,
        keymap.of([...defaultKeymap, ...historyKeymap, indentWithTab]),
        saveKeymap,
        themeCompartment.of(buildEditorTheme(theme)),
        editableCompartment.of(EditorView.editable.of(true)),
        EditorView.updateListener.of(u => {
          if (u.docChanged) {
            onChangeRef.current(u.state.doc.toString());
          }
        }),
      ],
    });

    const view = new EditorView({ state, parent: hostRef.current });
    viewRef.current = view;
    return () => { view.destroy(); viewRef.current = null; };
    // theme intentionally not in deps — handled by the hot-swap effect below
    // so we don't lose caret/selection/history when settings change.
    // initial intentionally not in deps — we don't reseed mid-edit.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [docId]);

  // Hot-swap the theme compartment when dark mode flips. Font face / size /
  // line-height live in CSS vars, so they update without a reconfigure.
  useEffect(() => {
    const view = viewRef.current;
    if (!view) return;
    view.dispatch({
      effects: themeCompartment.reconfigure(buildEditorTheme(theme)),
    });
  }, [theme.dark]);

  return <div ref={hostRef} class="h-full overflow-auto scrollbar-thin" />;
}
