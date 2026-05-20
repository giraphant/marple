import { useEffect, useRef, useState } from 'preact/hooks';
import { EditorView, keymap, drawSelection, Decoration, ViewPlugin, WidgetType } from '@codemirror/view';
import type { DecorationSet, ViewUpdate } from '@codemirror/view';
import type { ChangeSpec, Extension } from '@codemirror/state';
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
    caret:    '#3d93ea',  /* Ulysses/macOS insertion point is blue in Blush */
    selection:'#dcecff',
    markup:   '#bfbfbf',  /* markup 字符（*、>、# 等）— 比正文淡 */
    hr:       '#d4d4d4',
    /* 语义色 — 直接拷自 styles.css --reader-* */
    heading:  '#fa9600',
    headingMarkup: '#f4d6ad',
    strong:   '#9d6ad8',
    em:       '#ff5f8b',
    quote:    '#bd693f',
    quoteMarker: '#dfc6b7',
    quoteLineBg: '#f5ebe2',  /* 浅桃色 — blockquote 整行 bg */
    code:     '#3d93ea',
    codeBg:   '#e8eef5',
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
    headingMarkup: '#7f693c',
    strong:   '#ac81f3',
    em:       '#ff4771',
    quote:    '#ecddd9',
    quoteMarker: '#8b7a84',
    quoteLineBg: '#3c3037',  /* 比 page bg 略亮的酒红 wash */
    code:     '#0097de',
    codeBg:   '#263545',
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
  /** Exposes the live EditorView (or null on teardown) so the parent can drive
   * imperative actions like scroll-to-line for the outline panel (QUA-57). */
  onViewReady?: (view: EditorView | null) => void;
}

type SemanticTokenKind = 'wiki' | 'link' | 'image' | 'footnote';

interface SemanticToken {
  kind: SemanticTokenKind;
  from: number;
  to: number;
  raw: string;
  label: string;
  target: string;
  secondary?: string;
}

interface SemanticPopover extends SemanticToken {
  left: number;
  top: number;
  draftLabel: string;
  draftTarget: string;
  draftText: string;
}

type OpenSemanticPopover = (view: EditorView, token: SemanticToken, rect: DOMRect) => void;

const SEMANTIC_TOKEN_CLASS_BY_KIND: Record<SemanticTokenKind, string> = {
  wiki: 'cm-semantic-wiki',
  link: 'cm-semantic-link',
  image: 'cm-semantic-image',
  footnote: 'cm-semantic-footnote',
};

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
//  (2) list marker slot — 列表源码 marker (`- ` / `1. `) 被替换成固定槽位里
//      右对齐的短 marker，正文再整体后退。这样 marker 长短不再扰动正文列。
//  (3) blockquote 整行 bg — `>` 开头的行加 `cm-blockquote-line` class 触发 bg。
//      不按 syntaxTree 的 Blockquote 节点范围（CommonMark 的 lazy continuation
//      会把两个 `>` 之间的 plain 行吞进去）。Ulysses Markdown XL 是逐行判断。
//
// MARKER_RE 捕获：(leading-ws)(marker-chars)(trailing-ws)。
// 计算 text-indent 时用 marker+trailing-ws 的字符数 —— 让 marker 后第一个
// 实际正文字符落到非 marker 行同列。
// 标题 / 列表必须有 ≥1 个尾随空格才成立（CommonMark：`#foo`/`-foo` 不算）。
const MARKER_RE = /^(\s*)(#{1,6}|[-*+]|\d{1,3}[.)])(\s+)/;
// blockquote 单独处理：CommonMark 里 `>` 后的空格是可选的，`>foo` 同样是引用块。
// 所以删掉 `> ` 的空格不应丢掉引用格式 —— 这里允许最多一个尾随空格。
const QUOTE_RE = /^(\s*)(>)( ?)/;
const LIST_MARKER_RE = /^[-*+]|^\d/;

class ListMarkerWidget extends WidgetType {
  constructor(private readonly marker: string) { super(); }

  eq(other: WidgetType): boolean {
    return other instanceof ListMarkerWidget && other.marker === this.marker;
  }

  toDOM(): HTMLElement {
    const span = document.createElement('span');
    span.className = 'cm-list-rendered-marker';
    span.textContent = /^\d/.test(this.marker) ? this.marker : '‐';
    span.title = this.marker;
    return span;
  }

  ignoreEvent(): boolean {
    return false;
  }
}

class DividerWidget extends WidgetType {
  constructor(private readonly raw: string) { super(); }

  eq(other: WidgetType): boolean {
    return other instanceof DividerWidget && other.raw === this.raw;
  }

  toDOM(): HTMLElement {
    const span = document.createElement('span');
    span.className = 'cm-hr-rendered';
    span.textContent = '----';
    span.title = this.raw;
    return span;
  }

  ignoreEvent(): boolean {
    return false;
  }
}

function computeMarkerDeco(view: EditorView): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  for (const { from, to } of view.visibleRanges) {
    let pos = from;
    while (pos <= to) {
      const line = view.state.doc.lineAt(pos);
      // Quote first (its trailing space is optional); then heading / list.
      const m = line.text.match(QUOTE_RE) ?? line.text.match(MARKER_RE);
      if (m) {
        const leadingSpaces = m[1].length;
        const marker = m[2];
        const trailing = m[3]; // quote: '' or ' ';  heading/list: the \s+
        const hangLen = marker.length + trailing.length;
        const isQuote = marker === '>';
        const isList = !isQuote && LIST_MARKER_RE.test(marker);

        let style: string | undefined;
        if (isList) {
          // List: line padding defines the marker slot origin; the source
          // marker+space is replaced by ListMarkerWidget, whose fixed-width
          // marker is right-aligned before the content column. text-indent pulls
          // the first line's marker back into the padding gutter so wrapped
          // continuation lines align with the body (hanging indent).
          // Body column = 4.25em (normal 3em + 1.25em indent, same as blockquote)
          // so the list is indented relative to normal paragraphs; deeper nesting
          // adds 2em/level. The marker widget hangs in the gutter via -1.25em.
          const nestedLevel = Math.floor(leadingSpaces / 2);
          const padEm = 4.25 + nestedLevel * 2;
          style = `padding-left: ${padEm}em; text-indent: -1.25em`;
        } else if (isQuote) {
          // Blockquote: body column = 4.25em (i.e. the normal 3em body column
          // PLUS a 1.25em indent), so the quote is visibly indented relative to
          // normal paragraphs. The fixed-width `>` marker (.cm-blockquote-marker,
          // 1.25em) hangs in that indent gutter via `text-indent: -1.25em`,
          // landing `>` at the 3em column and the body at 4.25em on the first
          // line and on every wrapped line.
          style = `padding-left: 4.25em; text-indent: -1.25em`;
        } else {
          // heading: marker 挂在 padding gutter 里，content 在 body column。
          // hangLen = marker 字符数 + trailing space，用 ch 让对齐到 body 段落同列。
          style = `text-indent: -${hangLen}ch`;
        }

        const lineAttrs = style ? { attributes: { style } } : {};
        const dec = isQuote
          ? Decoration.line({ class: 'cm-blockquote-line', ...lineAttrs })
          : isList
            ? Decoration.line({ class: 'cm-list-line', ...lineAttrs })
          : Decoration.line(lineAttrs);
        builder.add(line.from, line.from, dec);

        if (isQuote) {
          const markerFrom = line.from + leadingSpaces;
          const bodyFrom = markerFrom + marker.length + trailing.length;
          // Mark the whole `> ` (marker + trailing space) as one fixed-width
          // inline-block so the body starts at an exact column (CSS handles the
          // width / gap). Wrapped lines then align with it via the line's
          // text-indent.
          builder.add(markerFrom, bodyFrom, Decoration.mark({ class: 'cm-blockquote-marker' }));
          if (bodyFrom < line.to) {
            builder.add(bodyFrom, line.to, Decoration.mark({ class: 'cm-blockquote-text' }));
          }
        }

        if (isList) {
          // Replace the marker AND its trailing space with the fixed-width
          // widget, so the body starts exactly at the body column (padding-left)
          // and the `text-indent: -1.25em` makes wrapped lines align under the
          // first line's body (hanging indent). The widget's own right padding
          // supplies the marker→body gap.
          const markerTo = line.from + leadingSpaces + marker.length + trailing.length;
          if (!selectionTouchesToken(view, line.from, markerTo)) {
            builder.add(
              line.from,
              markerTo,
              Decoration.replace({
                widget: new ListMarkerWidget(marker),
                inclusive: false,
              }),
            );
          }
        }
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

const MARK_RE = /::.+?::/g;
const COMMENT_LINE_RE = /^\s*(?:%%.*|<!--.*?(?:-->)?)\s*$/;
const HR_LINE_RE = /^\s*-{3,}\s*$/;
const FOOTNOTE_DEFINITION_LINE_RE = /^\[\^([^\]\n]+)\]:\s?(.*)$/;
const FOOTNOTE_REFERENCE_RE = /\[\^([^\]\n]+)\](?!:)/g;
const FOOTNOTE_PLACEHOLDER_RE = /\[(fn)\]|\((fn)\)/gi;

function computeUlyssesSyntaxDeco(view: EditorView): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  for (const { from, to } of view.visibleRanges) {
    let pos = from;
    while (pos <= to) {
      const line = view.state.doc.lineAt(pos);
      const nextLine = line.to < view.state.doc.length ? view.state.doc.lineAt(line.to + 1) : null;
      const followedByDivider = Boolean(nextLine && HR_LINE_RE.test(nextLine.text));
      if (FOOTNOTE_DEFINITION_LINE_RE.test(line.text)) {
        builder.add(line.from, line.from, Decoration.line({ class: 'cm-footnote-definition-line' }));
      } else if (COMMENT_LINE_RE.test(line.text)) {
        builder.add(line.from, line.from, Decoration.line({ class: 'cm-comment-line' }));
        builder.add(line.from, line.to, Decoration.mark({ class: 'cm-comment' }));
      } else if (HR_LINE_RE.test(line.text)) {
        builder.add(line.from, line.from, Decoration.line({
          class: 'cm-hr-line',
          attributes: { style: 'text-indent: -1.75em' },
        }));
        if (selectionTouchesToken(view, line.from, line.to)) {
          builder.add(line.from, line.to, Decoration.mark({ class: 'cm-hr' }));
        } else {
          builder.add(line.from, line.to, Decoration.replace({
            widget: new DividerWidget(line.text.trim()),
            inclusive: false,
          }));
        }
      } else {
        if (followedByDivider && line.text.trim()) {
          builder.add(line.from, line.from, Decoration.line({ class: 'cm-before-hr-line' }));
          builder.add(line.from, line.to, Decoration.mark({ class: 'cm-before-hr-text' }));
        }
        MARK_RE.lastIndex = 0;
        let m: RegExpExecArray | null;
        while ((m = MARK_RE.exec(line.text))) {
          builder.add(
            line.from + m.index,
            line.from + m.index + m[0].length,
            Decoration.mark({ class: 'cm-ulysses-mark' }),
          );
        }
      }
      if (line.to + 1 > view.state.doc.length) break;
      pos = line.to + 1;
    }
  }
  return builder.finish();
}

const ulyssesSyntaxDecorations = ViewPlugin.fromClass(class {
  decorations: DecorationSet;
  constructor(view: EditorView) { this.decorations = computeUlyssesSyntaxDeco(view); }
  update(u: ViewUpdate) {
    if (u.docChanged || u.viewportChanged) this.decorations = computeUlyssesSyntaxDeco(u.view);
  }
}, { decorations: v => v.decorations });

const SEMANTIC_TOKEN_RE = /!\[([^\]\n]*)\]\(([^)\n]+)\)|\[\[([^\]\n]+)\]\]|\[([^\]\n]+)\]\(([^)\n]+)\)|\[\^([^\]\n]+)\]|\[(fn)\]|\((fn)\)/gi;

function isInsideInlineCode(text: string, index: number): boolean {
  let ticks = 0;
  for (let i = 0; i < index; i++) if (text[i] === '`') ticks++;
  return ticks % 2 === 1;
}

function selectionTouchesToken(view: EditorView, from: number, to: number): boolean {
  return view.state.selection.ranges.some(r => (
    r.empty ? r.from > from && r.from < to : r.from < to && r.to > from
  ));
}

function parseSemanticTokens(text: string, offset: number): SemanticToken[] {
  const out: SemanticToken[] = [];
  SEMANTIC_TOKEN_RE.lastIndex = 0;
  let m: RegExpExecArray | null;
  while ((m = SEMANTIC_TOKEN_RE.exec(text))) {
    if (isInsideInlineCode(text, m.index)) continue;
    const from = offset + m.index;
    const to = from + m[0].length;

    if (m[1] != null && m[2] != null) {
      out.push({
        kind: 'image',
        from, to,
        raw: m[0],
        label: m[1] || '图片',
        target: m[2],
        secondary: m[2],
      });
      continue;
    }

    if (m[3] != null) {
      const [target, alias] = m[3].split('|');
      out.push({
        kind: 'wiki',
        from, to,
        raw: m[0],
        label: (alias || target).trim(),
        target: target.trim(),
        secondary: target.trim(),
      });
      continue;
    }

    if (m[4] != null && m[5] != null) {
      out.push({
        kind: 'link',
        from, to,
        raw: m[0],
        label: m[4].trim(),
        target: m[5].trim(),
        secondary: m[5].trim(),
      });
      continue;
    }

    if (m[6] != null || m[7] != null || m[8] != null) {
      // Footnote definitions (`[^id]: text`) should stay textual; only fold refs.
      if (text[SEMANTIC_TOKEN_RE.lastIndex] === ':') continue;
      const id = (m[6] ?? m[7] ?? m[8]).trim();
      out.push({
        kind: 'footnote',
        from, to,
        raw: m[0],
        label: '*',
        target: id,
        secondary: id,
      });
    }
  }
  return out;
}

function computeSemanticTokenDeco(view: EditorView, openPopover: OpenSemanticPopover): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  for (const { from, to } of view.visibleRanges) {
    let pos = from;
    while (pos <= to) {
      const line = view.state.doc.lineAt(pos);
      for (const token of parseSemanticTokens(line.text, line.from)) {
        if (selectionTouchesToken(view, token.from, token.to)) continue;
        builder.add(
          token.from,
          token.to,
          Decoration.replace({
            widget: new SemanticTokenWidget(token, openPopover),
            inclusive: false,
          }),
        );
      }
      if (line.to + 1 > view.state.doc.length) break;
      pos = line.to + 1;
    }
  }
  return builder.finish();
}

class SemanticTokenWidget extends WidgetType {
  constructor(
    private readonly token: SemanticToken,
    private readonly openPopover: OpenSemanticPopover,
  ) {
    super();
  }

  eq(other: WidgetType): boolean {
    return other instanceof SemanticTokenWidget
      && other.token.kind === this.token.kind
      && other.token.raw === this.token.raw
      && other.token.from === this.token.from
      && other.token.to === this.token.to;
  }

  toDOM(view: EditorView): HTMLElement {
    const span = document.createElement('span');
    span.className = `cm-semantic-token ${SEMANTIC_TOKEN_CLASS_BY_KIND[this.token.kind]}`;
    if (this.token.kind === 'footnote') {
      const star = document.createElement('span');
      star.className = 'cm-semantic-footnote-star';
      star.textContent = this.token.label;
      span.appendChild(star);
    } else {
      span.textContent = this.token.kind === 'image' ? `图 ${this.token.label}` : this.token.label;
    }
    span.title = this.token.secondary || this.token.target;
    span.addEventListener('mousedown', ev => {
      ev.preventDefault();
      ev.stopPropagation();
    });
    span.addEventListener('click', ev => {
      ev.preventDefault();
      ev.stopPropagation();
      this.openPopover(view, this.token, span.getBoundingClientRect());
    });
    return span;
  }

  ignoreEvent(): boolean {
    return false;
  }
}

function semanticTokenDecorations(openPopover: OpenSemanticPopover): Extension {
  return ViewPlugin.fromClass(class {
    decorations: DecorationSet;
    constructor(view: EditorView) {
      this.decorations = computeSemanticTokenDeco(view, openPopover);
    }
    update(u: ViewUpdate) {
      if (u.docChanged || u.viewportChanged || u.selectionSet) {
        this.decorations = computeSemanticTokenDeco(u.view, openPopover);
      }
    }
  }, { decorations: v => v.decorations });
}

function findFootnoteDefinition(state: EditorState, id: string): { from: number; to: number; text: string } | null {
  const escaped = id.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const re = new RegExp(`^\\[\\^${escaped}\\]:\\s?(.*)$`);
  for (let n = 1; n <= state.doc.lines; n++) {
    const line = state.doc.line(n);
    const m = line.text.match(re);
    if (!m) continue;
    const textFrom = line.from + line.text.indexOf(m[1]);
    return { from: textFrom, to: line.to, text: m[1] };
  }
  return null;
}

function collectFootnoteIds(state: EditorState): Set<string> {
  const ids = new Set<string>();
  const text = state.doc.toString();
  let m: RegExpExecArray | null;
  const anyFootnoteRe = /\[\^([^\]\n]+)\]/g;
  while ((m = anyFootnoteRe.exec(text))) ids.add(m[1].trim());
  return ids;
}

function hasFootnoteReference(state: EditorState, id: string): boolean {
  for (let n = 1; n <= state.doc.lines; n++) {
    const line = state.doc.line(n);
    if (FOOTNOTE_DEFINITION_LINE_RE.test(line.text)) continue;
    FOOTNOTE_REFERENCE_RE.lastIndex = 0;
    let m: RegExpExecArray | null;
    while ((m = FOOTNOTE_REFERENCE_RE.exec(line.text))) {
      if (m[1].trim() === id) return true;
    }
  }
  return false;
}

function reserveNextFootnoteId(state: EditorState, reserved: Set<string>): string {
  const used = collectFootnoteIds(state);
  for (let n = 1; n < 10000; n++) {
    const id = `fn${n}`;
    if (!used.has(id) && !reserved.has(id)) {
      reserved.add(id);
      return id;
    }
  }
  const fallback = `fn-${Date.now().toString(36)}`;
  reserved.add(fallback);
  return fallback;
}

function remapPastedFootnotes(text: string, state: EditorState): { text: string; extraDefinitions: string } | null {
  const existingIds = collectFootnoteIds(state);
  const pastedDefinitionIds = new Set<string>();
  const reserved = new Set<string>();
  const idMap = new Map<string, string>();
  const extraDefinitions: string[] = [];
  let changed = false;

  for (const line of text.split('\n')) {
    const definitionMatch = line.match(FOOTNOTE_DEFINITION_LINE_RE);
    if (definitionMatch) pastedDefinitionIds.add(definitionMatch[1].trim());
  }

  const newIdForExisting = (id: string): string => {
    const normalized = id.trim();
    const known = idMap.get(normalized);
    if (known) return known;

    const nextId = reserveNextFootnoteId(state, reserved);
    idMap.set(normalized, nextId);
    const def = findFootnoteDefinition(state, normalized);
    if (def && !pastedDefinitionIds.has(normalized)) extraDefinitions.push(`[^${nextId}]: ${def.text}`);
    return nextId;
  };

  let nextText = text.replace(FOOTNOTE_PLACEHOLDER_RE, () => {
    changed = true;
    const nextId = reserveNextFootnoteId(state, reserved);
    const legacyDef = findFootnoteDefinition(state, 'fn');
    if (legacyDef) extraDefinitions.push(`[^${nextId}]: ${legacyDef.text}`);
    return `[^${nextId}]`;
  });

  nextText = nextText
    .split('\n')
    .map(line => {
      const definitionMatch = line.match(FOOTNOTE_DEFINITION_LINE_RE);
      if (definitionMatch && existingIds.has(definitionMatch[1].trim())) {
        changed = true;
        return line.replace(FOOTNOTE_DEFINITION_LINE_RE, `[^${newIdForExisting(definitionMatch[1])}]: $2`);
      }

      return line.replace(FOOTNOTE_REFERENCE_RE, (raw, id: string) => {
        if (!existingIds.has(id.trim())) return raw;
        changed = true;
        return `[^${newIdForExisting(id)}]`;
      });
    })
    .join('\n');

  if (!changed) return null;
  return { text: nextText, extraDefinitions: extraDefinitions.join('\n') };
}

function normalizeLegacyFootnotePlaceholders(view: EditorView): void {
  const state = view.state;
  const changes: ChangeSpec[] = [];
  const extraDefinitions: string[] = [];
  const reserved = new Set<string>();
  const legacyDef = findFootnoteDefinition(state, 'fn');
  const canReuseLegacyDefinition = Boolean(legacyDef) && !hasFootnoteReference(state, 'fn');
  let reusedLegacyDefinition = false;

  for (let n = 1; n <= state.doc.lines; n++) {
    const line = state.doc.line(n);
    FOOTNOTE_PLACEHOLDER_RE.lastIndex = 0;
    let m: RegExpExecArray | null;
    while ((m = FOOTNOTE_PLACEHOLDER_RE.exec(line.text))) {
      if (isInsideInlineCode(line.text, m.index)) continue;

      const id: string = canReuseLegacyDefinition && !reusedLegacyDefinition
        ? 'fn'
        : reserveNextFootnoteId(state, reserved);
      reusedLegacyDefinition = reusedLegacyDefinition || id === 'fn';
      if (legacyDef && id !== 'fn') extraDefinitions.push(`[^${id}]: ${legacyDef.text}`);

      changes.push({
        from: line.from + m.index,
        to: line.from + m.index + m[0].length,
        insert: `[^${id}]`,
      });
    }
  }

  if (!changes.length) return;
  if (extraDefinitions.length) {
    const docText = state.doc.toString();
    changes.push({
      from: state.doc.length,
      insert: `${docText.endsWith('\n') ? '\n' : '\n\n'}${extraDefinitions.join('\n')}`,
    });
  }
  view.dispatch({ changes, scrollIntoView: false });
}

function tokenDraftText(view: EditorView, token: SemanticToken): string {
  if (token.kind !== 'footnote') return '';
  return findFootnoteDefinition(view.state, token.target)?.text ?? '';
}

function justTypedFootnoteToken(update: ViewUpdate): SemanticToken | null {
  if (!update.docChanged) return null;
  if (!update.transactions.some(tr => tr.isUserEvent('input.type'))) return null;
  const head = update.state.selection.main.head;
  if (head < 4) return null;

  const candidates = [
    { raw: '(fn)', from: head - 4, to: head },
    { raw: '[fn]', from: head - 4, to: head },
  ];
  for (const c of candidates) {
    if (c.from < 0) continue;
    if (update.state.doc.sliceString(c.from, c.to).toLowerCase() !== c.raw) continue;
    return {
      kind: 'footnote',
      from: c.from,
      to: c.to,
      raw: c.raw,
      label: '*',
      target: 'fn',
      secondary: 'fn',
    };
  }
  return null;
}

function rectFromCoords(view: EditorView, pos: number): DOMRect | null {
  const coords = view.coordsAtPos(pos, -1) ?? view.coordsAtPos(pos, 1);
  if (!coords) return null;
  const width = Math.max(24, coords.right - coords.left);
  const height = Math.max(view.defaultLineHeight, coords.bottom - coords.top);
  return new DOMRect(coords.left - width, coords.top, width, height);
}

function clamp(n: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, n));
}

const footnotePasteHandler = EditorView.domEventHandlers({
  paste(event, view) {
    if (view.state.selection.ranges.length !== 1) return false;
    const text = event.clipboardData?.getData('text/plain');
    if (!text) return false;
    const remapped = remapPastedFootnotes(text, view.state);
    if (!remapped) return false;

    event.preventDefault();
    const selection = view.state.selection.main;
    let insert = remapped.text;
    const changes: ChangeSpec[] = [{ from: selection.from, to: selection.to, insert }];
    if (remapped.extraDefinitions) {
      const docText = view.state.doc.toString();
      const extra = `${docText.endsWith('\n') || selection.to === view.state.doc.length ? '\n' : '\n\n'}${remapped.extraDefinitions}`;
      if (selection.to === view.state.doc.length) {
        insert += extra;
        changes[0] = { from: selection.from, to: selection.to, insert };
      } else {
        changes.push({ from: view.state.doc.length, insert: extra });
      }
    }
    view.dispatch({
      changes,
      selection: { anchor: selection.from + insert.length },
      scrollIntoView: true,
      userEvent: 'input.paste',
    });
    return true;
  },
});

// Build the editor theme from settings — caller-controlled font, size, leading;
// rest of the visual language (off-white page, muted markers, warm caret) is
// constant and matches Ulysses sensibility.
function buildEditorTheme({ dark }: EditorThemeConfig): Extension {
  const p = dark ? PALETTE.dark : PALETTE.light;
  const inlineCodeStyle = {
    fontFamily: 'ui-monospace, "SF Mono", SFMono-Regular, "JetBrains Mono", monospace',
    backgroundColor: p.codeBg,
    color: p.code,
    padding: '1px 5px',
    borderRadius: '1px',
    fontSize: '0.9em',
    fontWeight: '400',
  };
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
      wordSpacing: '0.035em',
    },
    // padding-left 3em：给 markdown markers 留挂位 —— marker lines 加
    // text-indent:-Xch 后 marker 落到本 padding 范围内，正文文字落在 3em 开始处
    // 与所有 plain 行同列。padding-right 1.5em 给右侧呼吸感、避免文字贴边。
    '.cm-line': { paddingLeft: '3em', paddingRight: '1.5em' },
    '.cm-cursor': { borderLeftWidth: '2px', borderLeftColor: p.caret },
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
    '.cm-h1.cm-markup, .cm-h2.cm-markup, .cm-h3.cm-markup, .cm-h4.cm-markup, .cm-h5.cm-markup, .cm-h6.cm-markup': {
      color: p.headingMarkup,
    },

    '.cm-strong': { fontWeight: '700', color: p.strong },
    // emph: 粉色 + italic — CJK glyph 自然 fallback 成普通字重的彩色文本，
    // 西文 glyph 出真 italic。两端都能识别。
    '.cm-em': { color: p.em, fontStyle: 'italic' },
    '.cm-code': inlineCodeStyle,

    '.cm-markup': { color: p.markup },
    // CodeMirror tags the whole list item as `cm-list`; Ulysses only colors
    // the marker itself. Keep body text neutral, then recolor the first marker.
    '.cm-list': { color: p.fg, fontWeight: '400' },
    '.cm-list.cm-markup': { color: p.markup, fontWeight: '400' },
    '.cm-line > .cm-list.cm-markup:first-child': { color: p.marker, fontWeight: '700' },
    '.cm-list.cm-code': inlineCodeStyle,
    // hr 用粉色 — Ulysses Blush 里 `---` 是粉色横线。
    '.cm-hr':     { color: p.em },

    // Ulysses Markdown XL behaves visually line-by-line. CodeMirror's
    // CommonMark parser marks lazy blockquote continuation lines as quote;
    // keep parser-level quote neutral and color only explicit `>` lines via
    // cm-blockquote-* decorations.
    '.cm-quote': { color: p.fg, fontStyle: 'normal' },
    '.cm-quote.cm-markup': { color: p.markup, fontWeight: '400' },
    '.cm-blockquote-line': {
      backgroundColor: p.quoteLineBg,
      boxShadow: `-100vw 0 0 ${p.quoteLineBg}, 100vw 0 0 ${p.quoteLineBg}`,
    },

    '.cm-link': { color: p.link, fontWeight: '700' },
    '.cm-url':  { color: p.link, textDecoration: 'underline' },
  });
}

const editableCompartment = new Compartment();
const themeCompartment = new Compartment();

export function NoteEditor({ docId, initial, theme, onChange, onSaveShortcut, onViewReady }: Props) {
  const hostRef = useRef<HTMLDivElement>(null);
  const popoverRef = useRef<HTMLDivElement>(null);
  const viewRef = useRef<EditorView | null>(null);
  const onChangeRef = useRef(onChange);
  const onSaveRef = useRef(onSaveShortcut);
  const onViewReadyRef = useRef(onViewReady);
  const [popover, setPopover] = useState<SemanticPopover | null>(null);
  onChangeRef.current = onChange;
  onSaveRef.current = onSaveShortcut;
  onViewReadyRef.current = onViewReady;

  const openSemanticPopover: OpenSemanticPopover = (view, token, rect) => {
    const width = token.kind === 'footnote' ? 360 : 360;
    const height = token.kind === 'footnote' ? 112 : 148;
    const center = rect.left + rect.width / 2;
    const left = clamp(center - width / 2, 12, Math.max(12, window.innerWidth - width - 12));
    const below = rect.bottom + 10;
    const top = below + height > window.innerHeight - 12
      ? clamp(rect.top - height - 10, 12, window.innerHeight - height - 12)
      : below;

    setPopover({
      ...token,
      left,
      top,
      draftLabel: token.label,
      draftTarget: token.target,
      draftText: tokenDraftText(view, token),
    });
  };

  const commitPopover = (targetPopover: SemanticPopover, opts: { focusEditor: boolean }) => {
    const view = viewRef.current;
    if (!view) return;
    const label = targetPopover.draftLabel.trim();
    const target = targetPopover.draftTarget.trim();
    if (!target && targetPopover.kind !== 'footnote') return;

    let insert: string;
    if (targetPopover.kind === 'wiki') {
      insert = label && label !== target ? `[[${target}|${label}]]` : `[[${target}]]`;
    } else if (targetPopover.kind === 'link') {
      insert = `[${label || target}](${target})`;
    } else if (targetPopover.kind === 'image') {
      insert = `![${label}](${target})`;
    } else {
      const def = findFootnoteDefinition(view.state, targetPopover.target);
      const text = targetPopover.draftText.trimEnd();
      if (!def && !text.trim()) {
        if (opts.focusEditor) view.focus();
        return;
      }
      view.dispatch({
        changes: def
          ? { from: def.from, to: def.to, insert: text }
          : { from: view.state.doc.length, insert: `\n\n[^${targetPopover.target}]: ${text}` },
        scrollIntoView: false,
      });
      if (opts.focusEditor) view.focus();
      return;
    }

    view.dispatch({
      changes: { from: targetPopover.from, to: targetPopover.to, insert },
      selection: { anchor: targetPopover.from + insert.length },
      scrollIntoView: true,
    });
    if (opts.focusEditor) view.focus();
  };

  const revealRawToken = () => {
    const view = viewRef.current;
    if (!view || !popover) return;
    view.dispatch({
      selection: { anchor: popover.from, head: popover.to },
      scrollIntoView: true,
    });
    view.focus();
    setPopover(null);
  };

  const deleteTokenMarkup = () => {
    const view = viewRef.current;
    if (!view || !popover) return;
    const insert = popover.kind === 'image'
      ? popover.draftLabel
      : popover.kind === 'footnote'
        ? ''
        : popover.draftLabel || popover.draftTarget;
    view.dispatch({
      changes: { from: popover.from, to: popover.to, insert },
      selection: { anchor: popover.from + insert.length },
      scrollIntoView: true,
    });
    view.focus();
    setPopover(null);
  };

  const saveSemanticToken = () => {
    if (!popover) return;
    commitPopover(popover, { focusEditor: true });
    setPopover(null);
  };

  // Rebuild the editor only when docId changes — otherwise updates would clobber
  // the user's caret / selection / history.
  useEffect(() => {
    if (!hostRef.current) return;
    setPopover(null);

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
        ulyssesSyntaxDecorations,
        semanticTokenDecorations(openSemanticPopover),
        footnotePasteHandler,
        EditorView.lineWrapping,
        keymap.of([...defaultKeymap, ...historyKeymap, indentWithTab]),
        saveKeymap,
        themeCompartment.of(buildEditorTheme(theme)),
        editableCompartment.of(EditorView.editable.of(true)),
        EditorView.updateListener.of(u => {
          if (u.docChanged) {
            onChangeRef.current(u.state.doc.toString());
            const footnoteToken = justTypedFootnoteToken(u);
            if (footnoteToken) {
              const id = reserveNextFootnoteId(u.state, new Set());
              const raw = `[^${id}]`;
              const normalizedToken = {
                ...footnoteToken,
                to: footnoteToken.from + raw.length,
                raw,
                target: id,
                secondary: id,
              };
              u.view.dispatch({
                changes: { from: footnoteToken.from, to: footnoteToken.to, insert: raw },
                selection: { anchor: footnoteToken.from + raw.length },
                scrollIntoView: false,
              });
              requestAnimationFrame(() => {
                const rect = rectFromCoords(u.view, normalizedToken.to);
                if (rect) openSemanticPopover(u.view, normalizedToken, rect);
              });
            }
          }
        }),
      ],
    });

    const view = new EditorView({ state, parent: hostRef.current });
    viewRef.current = view;
    onViewReadyRef.current?.(view);
    requestAnimationFrame(() => normalizeLegacyFootnotePlaceholders(view));
    return () => { onViewReadyRef.current?.(null); view.destroy(); viewRef.current = null; };
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

  useEffect(() => {
    if (!popover) return;
    const onPointerDown = (ev: PointerEvent) => {
      const root = popoverRef.current;
      if (root?.contains(ev.target as Node)) return;
      if (popover.kind === 'footnote') commitPopover(popover, { focusEditor: false });
      setPopover(null);
    };
    document.addEventListener('pointerdown', onPointerDown, true);
    return () => document.removeEventListener('pointerdown', onPointerDown, true);
  }, [popover]);

  return (
    <div class="h-full relative">
      <div ref={hostRef} class="h-full overflow-auto scrollbar-thin" />
      {popover && (
        <div
          ref={popoverRef}
          class={`semantic-token-popover semantic-token-popover-${popover.kind}`}
          style={{
            left: `${popover.left}px`,
            top: `${popover.top}px`,
          }}
        >
          {popover.kind === 'footnote' ? (
            <label class="semantic-footnote-editor-wrap">
              <textarea
                autoFocus
                class="semantic-footnote-editor"
                value={popover.draftText}
                placeholder="输入脚注"
                onInput={e => setPopover(p => p ? { ...p, draftText: (e.currentTarget as HTMLTextAreaElement).value } : p)}
              />
            </label>
          ) : (
            <>
              <label class="semantic-token-field">
                <span>{popover.kind === 'image' ? '说明' : '显示文本'}</span>
                <input
                  autoFocus
                  value={popover.draftLabel}
                  onInput={e => setPopover(p => p ? { ...p, draftLabel: (e.currentTarget as HTMLInputElement).value } : p)}
                />
              </label>
              <label class="semantic-token-field">
                <span>{popover.kind === 'wiki' ? '目标' : '地址'}</span>
                <input
                  value={popover.draftTarget}
                  onInput={e => setPopover(p => p ? { ...p, draftTarget: (e.currentTarget as HTMLInputElement).value } : p)}
                />
              </label>
            </>
          )}

          {popover.kind !== 'footnote' && (
            <div class="semantic-token-actions">
              <button type="button" onClick={deleteTokenMarkup}>
                {popover.kind === 'image' ? '移除图片语法' : '删除链接'}
              </button>
              <button type="button" onClick={revealRawToken}>源码</button>
              <button type="button" onClick={saveSemanticToken}>完成</button>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
