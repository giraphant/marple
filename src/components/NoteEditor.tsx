import { useEffect, useRef } from 'preact/hooks';
import { EditorView, keymap, drawSelection } from '@codemirror/view';
import type { Extension } from '@codemirror/state';
import { EditorState, Compartment } from '@codemirror/state';
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

// Editor color palettes. Light is unchanged from the original Ulysses-flavored
// theme; dark mirrors the same warmth on a near-black canvas.
const PALETTE = {
  light: {
    bg:       '#fafaf9',
    fg:       '#1c1917',
    fgHi:     '#0c0a09',
    fgMed:    '#57534e',
    caret:    '#78716c',
    selection:'#fef3c7',
    markup:   '#d6d3d1',
    hr:       '#e7e5e4',
    codeBg:   '#f4f4f3',
    link:     '#0369a1',
  },
  dark: {
    bg:       '#1c1915',  /* matches --bg-page in styles.css */
    fg:       '#ebe2d5',  /* matches --text-primary */
    fgHi:     '#f5ede0',
    fgMed:    '#b4a796',
    caret:    '#b4a796',
    selection:'#7c3a08',  /* deep warm amber for selection */
    markup:   '#82736b',  /* close to --text-faint, muted markers */
    hr:       '#4e453b',  /* matches --border-strong */
    codeBg:   '#363128',
    link:     '#7dd3fc',
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
    },
    '.cm-line': { padding: '0 16px' },
    '.cm-cursor': { borderLeftWidth: '1px', borderLeftColor: p.caret },
    '&.cm-focused .cm-selectionBackground, ::selection': { backgroundColor: `${p.selection} !important` },

    '.cm-h1': { fontSize: '1.7em',  fontWeight: '700', color: p.fgHi, lineHeight: '1.25', letterSpacing: '-0.01em' },
    '.cm-h2': { fontSize: '1.4em',  fontWeight: '700', color: p.fgHi, lineHeight: '1.3' },
    '.cm-h3': { fontSize: '1.2em',  fontWeight: '600', color: p.fg },
    '.cm-h4': { fontSize: '1.08em', fontWeight: '600' },
    '.cm-h5': { fontSize: '1em',    fontWeight: '600' },
    '.cm-h6': { fontSize: '1em',    fontWeight: '600' },

    '.cm-strong': { fontWeight: '700', color: p.fgHi },
    '.cm-em': { fontStyle: 'italic' },
    '.cm-code': {
      fontFamily: 'ui-monospace, "SF Mono", SFMono-Regular, "JetBrains Mono", monospace',
      backgroundColor: p.codeBg,
      padding: '0 4px',
      borderRadius: '3px',
      fontSize: '0.9em',
    },

    '.cm-markup': { color: p.markup },
    '.cm-list':   { color: p.markup },
    '.cm-hr':     { color: p.hr },

    '.cm-quote': { color: p.fgMed, fontStyle: 'italic' },

    '.cm-link': { color: p.link },
    '.cm-url': { color: p.link, textDecoration: 'underline' },
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
