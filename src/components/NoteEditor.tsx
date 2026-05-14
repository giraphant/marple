import { useEffect, useRef } from 'preact/hooks';
import { EditorView, keymap, drawSelection } from '@codemirror/view';
import { EditorState, Compartment } from '@codemirror/state';
import { defaultKeymap, history, historyKeymap, indentWithTab } from '@codemirror/commands';
import { markdown } from '@codemirror/lang-markdown';
import { HighlightStyle, syntaxHighlighting } from '@codemirror/language';
import { tags as t } from '@lezer/highlight';

interface Props {
  /** Stable identifier; reinit the editor when this changes (entry switch). */
  docId: string;
  /** Initial body text. We never re-seed after mount unless `docId` changes. */
  initial: string;
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

// Ulysses-style typography: print-feeling serif, off-white page, generous
// whitespace, markers nearly fade out. No active-line highlight (Ulysses has
// none). Caret is a warm hair-line.
const editorTheme = EditorView.theme({
  '&': {
    height: '100%',
    backgroundColor: '#fafaf9',
    color: '#1c1917',
  },
  '&.cm-focused': { outline: 'none' },
  '.cm-scroller': {
    fontFamily: '"PingFang SC", "PingFang TC", -apple-system, BlinkMacSystemFont, "Helvetica Neue", "Hiragino Sans GB", system-ui, sans-serif',
    fontSize: '16px',
    lineHeight: '1.78',
    padding: '8px 0',
  },
  '.cm-content': {
    maxWidth: '680px',
    margin: '0 auto',
    padding: '48px 8px 60vh 8px',
    caretColor: '#78716c',
  },
  '.cm-line': { padding: '0 16px' },
  '.cm-cursor': { borderLeftWidth: '1px', borderLeftColor: '#78716c' },
  '&.cm-focused .cm-selectionBackground, ::selection': { backgroundColor: '#fef3c7 !important' },

  // Headings: bigger contrast, tighter leading, more breathing room above.
  '.cm-h1': { fontSize: '1.7em',  fontWeight: '700', color: '#0c0a09', lineHeight: '1.25', letterSpacing: '-0.01em' },
  '.cm-h2': { fontSize: '1.4em',  fontWeight: '700', color: '#0c0a09', lineHeight: '1.3' },
  '.cm-h3': { fontSize: '1.2em',  fontWeight: '600', color: '#1c1917' },
  '.cm-h4': { fontSize: '1.08em', fontWeight: '600' },
  '.cm-h5': { fontSize: '1em',    fontWeight: '600' },
  '.cm-h6': { fontSize: '1em',    fontWeight: '600' },

  // Inline emphasis: content stands out, markers nearly vanish.
  '.cm-strong': { fontWeight: '700', color: '#0c0a09' },
  '.cm-em': { fontStyle: 'italic' },
  '.cm-code': {
    fontFamily: 'ui-monospace, "SF Mono", SFMono-Regular, "JetBrains Mono", monospace',
    backgroundColor: '#f4f4f3',
    padding: '0 4px',
    borderRadius: '3px',
    fontSize: '0.9em',
  },

  // Markers (# ## > * - **) and atom-y bits: drop almost to background level.
  '.cm-markup': { color: '#d6d3d1' },
  '.cm-list':   { color: '#d6d3d1' },
  '.cm-hr':     { color: '#e7e5e4' },

  // Blockquote — muted serif italic, no left bar (CM6 source mode can't put
  // a true bar without decorations; we settle for the > marker plus colour).
  '.cm-quote': { color: '#57534e', fontStyle: 'italic' },

  // Links
  '.cm-link': { color: '#0369a1' },
  '.cm-url': { color: '#0369a1', textDecoration: 'underline' },
});

// Compartments let us swap config without rebuilding state. Right now we only
// need a stable identity for the editor; future focus-mode / typewriter
// toggles will hang off here.
const editableCompartment = new Compartment();

export function NoteEditor({ docId, initial, onChange, onSaveShortcut }: Props) {
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
        editorTheme,
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
    // initial intentionally not in deps — we don't reseed mid-edit.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [docId]);

  return <div ref={hostRef} class="h-full overflow-auto scrollbar-thin" />;
}
