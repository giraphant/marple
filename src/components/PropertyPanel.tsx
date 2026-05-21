import { useMemo, useState, useRef, useEffect } from 'preact/hooks';
import type { JSX, ComponentChildren } from 'preact';
import type { Entry, EntryType } from '../types';
import { splitAuthors } from '../wiki';
import { patchFrontmatter, applyFmToEntry, openPdfExternal, openTranslationExternal } from '../api';
import { ratingToStars } from '../frontmatter';
import { buildCitation, CITATION_FORMATS, type CitationFormat } from '../citation';
import { MiniRow } from './MiniRow';
import { Icon } from './Icon';

/** Which property rows apply to each entry type. Driven by the underlying
 * file shape (an author profile has no year / DOI; a note has no rating).
 * Themes + annotations + works render via separate sections, not here. */
const FIELDS_BY_TYPE: Record<EntryType, ReadonlySet<string>> = {
  'paper-analysis':  new Set(['rating', 'year', 'author', 'source', 'doi', 'topic']),
  'book-overview':   new Set(['rating', 'year', 'author', 'source', 'topic', 'chapters_analyzed']),
  'chapter-summary': new Set(['rating', 'year', 'author', 'source', 'topic']),
  'author-profile':  new Set(['rating']),
  'topic-synthesis': new Set(['rating', 'topic']),
  'note':            new Set([]),
};

interface Props {
  entry: Entry;
  entries: Entry[];
  authorIndex: Map<string, Entry[]>;
  annotationIndex: Map<string, Entry[]>;
  onOpen: (entry: Entry) => void;
  onThemeClick: (theme: string) => void;
  onUpdated: (updated: Entry) => void;
  onCreateAnnotation: (target: Entry) => Promise<void>;
}

type SaveFn = (mutate: (fm: Record<string, unknown>) => Record<string, unknown>) => Promise<void>;

export function PropertyPanel({
  entry, entries, authorIndex, annotationIndex,
  onOpen, onThemeClick, onUpdated, onCreateAnnotation,
}: Props) {
  // saving / err are panel-wide flags so we can disable rows during a write.
  const [saving, setSaving] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const save: SaveFn = async (mutate) => {
    setSaving(true); setErr(null);
    try {
      const newFm = await patchFrontmatter(entry.path, fm => mutate(fm));
      const updated = applyFmToEntry(entry, newFm);
      onUpdated(updated);
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setSaving(false);
    }
  };

  const backlinks = useMemo(() => {
    const out: {
      /** All works by this author (only on author-profile pages). Split by type at render time. */
      works?: Entry[];
      /** Other works by the SAME author (on paper / book pages). Split at render. */
      siblings?: Entry[];
      /** Same-type entries that share ≥ 2 themes with this one. */
      similar?: Entry[];
      authorProfile?: Entry;
    } = {};

    if (entry.type === 'author-profile') {
      const key = (entry.title ?? '').toLowerCase().trim();
      const works = key ? (authorIndex.get(key) ?? []) : [];
      out.works = [...works].sort((a, b) => (b.rating_score || 0) - (a.rating_score || 0));
    }

    if (entry.type === 'paper-analysis' || entry.type === 'book-overview') {
      const names = splitAuthors(entry.author);
      const siblings = new Set<Entry>();
      let profile: Entry | undefined;
      for (const n of names) {
        const key = n.toLowerCase();
        if (!profile) {
          profile = entries.find(e => e.type === 'author-profile' && (e.title ?? '').toLowerCase() === key);
        }
        for (const w of (authorIndex.get(key) ?? [])) if (w.path !== entry.path) siblings.add(w);
      }
      out.authorProfile = profile;
      out.siblings = [...siblings]
        .sort((a, b) => (b.rating_score || 0) - (a.rating_score || 0));

      const own = new Set(entry.themes ?? []);
      if (own.size >= 2) {
        const scored: [number, Entry][] = [];
        for (const e of entries) {
          if (e.path === entry.path) continue;
          if (e.type !== entry.type) continue;
          let n = 0;
          for (const th of (e.themes ?? [])) if (own.has(th)) n++;
          if (n >= 2) scored.push([n, e]);
        }
        scored.sort((a, b) => b[0] - a[0] || (b[1].rating_score || 0) - (a[1].rating_score || 0));
        out.similar = scored.slice(0, 6).map(x => x[1]);
      }
    }
    return out;
  }, [entry, entries, authorIndex]);

  const themes = entry.themes ?? [];
  const myAnnotations = annotationIndex.get(entry.path) ?? [];
  const annotatesTarget = entry.type === 'note' && entry.annotates
    ? entries.find(e => e.path === entry.annotates)
    : null;

  const [creatingNote, setCreatingNote] = useState(false);
  const handleCreate = async () => {
    setCreatingNote(true); setErr(null);
    try { await onCreateAnnotation(entry); }
    catch (e) { setErr(e instanceof Error ? e.message : String(e)); }
    finally { setCreatingNote(false); }
  };

  return (
    <div class="p-5 space-y-5 text-[12px] text-secondary">
      {err && (
        <div class="text-[11px] px-2 py-1 rounded bg-danger-bg text-danger border border-danger/30">
          保存失败：{err}
        </div>
      )}

      {entry.type === 'note' && annotatesTarget && (
        <div class="text-[11px] px-2 py-1.5 rounded bg-type-note-bg text-type-note-fg border border-type-note-fg/25">
          批注于 <button onClick={() => onOpen(annotatesTarget)} class="font-medium underline hover:text-type-note-fg">
            {annotatesTarget.title || annotatesTarget.path.split('/').pop()}
          </button>
        </div>
      )}

      {(() => {
        const fields = FIELDS_BY_TYPE[entry.type];
        if (fields.size === 0) return null;
        return (
          <div>
            <div class="text-[11px] uppercase tracking-wider text-muted font-semibold mb-2">属性</div>
            <dl class={`space-y-2 ${saving ? 'opacity-60 pointer-events-none' : ''}`}>
            {fields.has('rating') && <RatingRow value={entry.rating_score} save={save} />}
            {fields.has('year') && <TextRow label="年份" value={entry.year} field="year" parse={parseYear} save={save} />}
            {fields.has('author') && <AuthorRow entry={entry} backlinks={backlinks} onOpen={onOpen} save={save} />}
            {fields.has('source') && <TextRow label="来源" value={entry.source} field="source" save={save} />}
            {fields.has('doi') && <DoiRow value={entry.doi} save={save} />}
            {fields.has('topic') && <TextRow label="专题" value={entry.topic} field="topic" save={save} />}
            {fields.has('chapters_analyzed') && entry.chapters_analyzed != null && (
              <div class="grid grid-cols-[60px_1fr] gap-2">
                <dt class="text-muted text-[11px] pt-0.5">章节数</dt>
                <dd class="min-w-0 tabular-nums">{entry.chapters_analyzed}</dd>
              </div>
            )}
            </dl>
          </div>
        );
      })()}

      <ThemesEditor themes={themes} onThemeClick={onThemeClick} save={save} disabled={saving} />

      {entry.type !== 'note' && (
        <div>
          <div class="flex items-center justify-between mb-1">
            <div class="text-[11px] uppercase tracking-wider text-muted font-semibold">
              我的批注{myAnnotations.length > 0 && ` (${myAnnotations.length})`}
            </div>
            <button
              onClick={handleCreate}
              disabled={creatingNote}
              class="text-[10px] text-type-note-fg hover:bg-type-note-bg border border-type-note-fg/25 px-1.5 py-0.5 rounded disabled:opacity-50"
            >
              {creatingNote ? '创建中…' : '+ 新建批注'}
            </button>
          </div>
          {myAnnotations.length > 0 ? (
            <div class="space-y-0.5">
              {myAnnotations.map(n => <MiniRow entry={n} onClick={onOpen} key={n.path} />)}
            </div>
          ) : (
            <div class="text-[11px] text-muted pl-2">—</div>
          )}
        </div>
      )}

      {backlinks.works && backlinks.works.length > 0 && (() => {
        const books = backlinks.works.filter(w => w.type === 'book-overview');
        const papers = backlinks.works.filter(w => w.type === 'paper-analysis');
        const renderGroup = (title: string, list: Entry[]) => list.length > 0 && (
          <Section title={`${title} (${list.length})`}>
            {list.slice(0, 30).map(w => <MiniRow entry={w} onClick={onOpen} key={w.path} />)}
            {list.length > 30 && (
              <div class="text-[10px] text-muted pl-2">+{list.length - 30} 条</div>
            )}
          </Section>
        );
        return <>{renderGroup('图书', books)}{renderGroup('论文', papers)}</>;
      })()}

      {backlinks.siblings && backlinks.siblings.length > 0 && (() => {
        const books = backlinks.siblings.filter(w => w.type === 'book-overview');
        const papers = backlinks.siblings.filter(w => w.type === 'paper-analysis');
        const renderGroup = (label: string, list: Entry[]) => list.length > 0 && (
          <Section title={`同作者 · ${label}`}>
            {list.slice(0, 8).map(w => <MiniRow entry={w} onClick={onOpen} key={w.path} />)}
            {list.length > 8 && (
              <div class="text-[10px] text-muted pl-2">+{list.length - 8} 条</div>
            )}
          </Section>
        );
        return <>{renderGroup('图书', books)}{renderGroup('论文', papers)}</>;
      })()}

      {backlinks.similar && backlinks.similar.length > 0 && (
        <Section title="同主题相似">
          {backlinks.similar.map(w => <MiniRow entry={w} onClick={onOpen} key={w.path} />)}
        </Section>
      )}
    </div>
  );
}

export function ActionsRow({ entry, defaultFormat, hasTranslation }: { entry: Entry; defaultFormat: CitationFormat; hasTranslation?: boolean }) {
  // Per-document override so the user can pick another format on the fly
  // without going back to settings. Resets when entry changes.
  const [format, setFormat] = useState<CitationFormat>(defaultFormat);
  const [copied, setCopied] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [menuOpen, setMenuOpen] = useState(false);
  const menuRef = useRef<HTMLDivElement>(null);
  const [readMenuOpen, setReadMenuOpen] = useState(false);
  const readMenuRef = useRef<HTMLDivElement>(null);

  useEffect(() => { setFormat(defaultFormat); }, [defaultFormat, entry.path]);

  // Click-outside to close the format menu.
  useEffect(() => {
    if (!menuOpen) return;
    const onDocClick = (e: MouseEvent) => {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) setMenuOpen(false);
    };
    document.addEventListener('mousedown', onDocClick);
    return () => document.removeEventListener('mousedown', onDocClick);
  }, [menuOpen]);

  // Click-outside to close the read (原文/译本) menu.
  useEffect(() => {
    if (!readMenuOpen) return;
    const onDocClick = (e: MouseEvent) => {
      if (readMenuRef.current && !readMenuRef.current.contains(e.target as Node)) setReadMenuOpen(false);
    };
    document.addEventListener('mousedown', onDocClick);
    return () => document.removeEventListener('mousedown', onDocClick);
  }, [readMenuOpen]);

  const copyCitation = async () => {
    setErr(null);
    const text = buildCitation(entry, format);
    if (!text) { setErr('引用字段不全'); return; }
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch (e) {
      setErr(e instanceof Error ? e.message : '复制失败');
    }
  };

  const openPdf = async () => {
    if (!entry.pdf_slug) return;
    setErr(null);
    try {
      await openPdfExternal(entry.pdf_slug);
    } catch (e) {
      setErr(e instanceof Error ? e.message : '打开原文失败');
    }
  };

  const openTranslation = async () => {
    if (!entry.pdf_slug) return;
    setErr(null);
    try {
      await openTranslationExternal(entry.pdf_slug);
    } catch (e) {
      setErr(e instanceof Error ? e.message : '打开译本失败');
    }
  };

  const activeMeta = CITATION_FORMATS.find(f => f.id === format);
  const preview = buildCitation(entry, format);

  // Read targets share one control like 复制引用: a primary button (原文) + a ▾
  // that folds out the alternatives (译本). Only the available ones appear.
  const readTargets: { label: string; run: () => void }[] = [];
  if (entry.has_pdf && entry.pdf_slug) readTargets.push({ label: '阅读原文', run: openPdf });
  if (hasTranslation && entry.pdf_slug) readTargets.push({ label: '阅读译本', run: openTranslation });

  return (
    <div class="flex items-center gap-2 -mt-1 text-[11px] flex-wrap">
      <div class="relative" ref={menuRef}>
        <div class="inline-flex rounded-lg border border-base bg-surface overflow-hidden">
          <button
            onClick={copyCitation}
            class="px-2 py-1 hover:bg-page text-secondary hover:text-primary transition"
            title={`格式：${activeMeta?.label ?? format}\n\n预览：${preview.slice(0, 200) || '(字段不全)'}`}
          >
            {copied ? '✓ 已复制' : '复制引用'}
          </button>
          <button
            onClick={() => setMenuOpen(v => !v)}
            class="px-1.5 py-1 border-l border-base hover:bg-page text-muted hover:text-primary transition"
            title="切换引用格式"
            aria-label="切换引用格式"
          >▾</button>
        </div>
        {menuOpen && (
          <div class="absolute right-0 top-full mt-1 z-20 bg-surface border border-base rounded-xl shadow-soft-lg py-1 w-[260px]">
            {CITATION_FORMATS.map(f => {
              const isActive = f.id === format;
              const ex = buildCitation(entry, f.id);
              return (
                <button
                  key={f.id}
                  onClick={() => { setFormat(f.id); setMenuOpen(false); }}
                  class={`w-full text-left px-3 py-1.5 hover:bg-page ${isActive ? 'bg-page' : ''}`}
                >
                  <div class="text-[12px] text-primary flex items-center gap-1.5">
                    <span class={`inline-block w-1 h-1 rounded-full ${isActive ? 'bg-accent' : 'bg-transparent'}`} />
                    {f.label}
                    <span class="text-muted text-[10px] ml-1">{f.hint}</span>
                  </div>
                  <div class="text-[11px] text-muted mt-0.5 truncate">
                    {ex || <span class="text-muted">字段不全</span>}
                  </div>
                </button>
              );
            })}
          </div>
        )}
      </div>
      {readTargets.length === 1 && (
        <button
          onClick={readTargets[0].run}
          class="px-2 py-1 rounded-lg border border-base bg-surface hover:border-strong text-secondary hover:text-primary transition"
        >{readTargets[0].label}</button>
      )}
      {readTargets.length >= 2 && (
        <div class="relative" ref={readMenuRef}>
          <div class="inline-flex rounded-lg border border-base bg-surface overflow-hidden">
            <button
              onClick={readTargets[0].run}
              class="px-2 py-1 hover:bg-page text-secondary hover:text-primary transition"
            >{readTargets[0].label}</button>
            <button
              onClick={() => setReadMenuOpen(v => !v)}
              class="px-1.5 py-1 border-l border-base hover:bg-page text-muted hover:text-primary transition"
              title="其它阅读方式"
              aria-label="其它阅读方式"
            >▾</button>
          </div>
          {readMenuOpen && (
            <div class="absolute right-0 top-full mt-1 z-20 bg-surface border border-base rounded-xl shadow-soft-lg py-1 w-[140px]">
              {readTargets.slice(1).map(t => (
                <button
                  key={t.label}
                  onClick={() => { t.run(); setReadMenuOpen(false); }}
                  class="w-full text-left px-3 py-1.5 text-[12px] text-primary hover:bg-page"
                >{t.label}</button>
              ))}
            </div>
          )}
        </div>
      )}
      {err && <span class="text-danger text-[10px]">{err}</span>}
    </div>
  );
}

function Section({ title, children }: { title: string; children: ComponentChildren }) {
  return (
    <div>
      <div class="text-[11px] uppercase tracking-wider text-muted font-semibold mb-1">{title}</div>
      <div class="space-y-0.5">{children}</div>
    </div>
  );
}

function Row({ label, children }: { label: string; children: ComponentChildren }) {
  return (
    <div class="editable-row grid grid-cols-[60px_1fr] gap-2 items-start">
      <dt class="text-muted text-[11px] pt-0.5">{label}</dt>
      <dd class="min-w-0">{children}</dd>
    </div>
  );
}

function RatingRow({ value, save }: { value: number; save: SaveFn }) {
  const display = value > 0 ? '★'.repeat(value) : <span class="text-muted">—</span>;
  const [editing, setEditing] = useState(false);
  if (!editing) {
    return (
      <Row label="评分">
        <button class="text-star text-left hover:bg-surface-2 px-1 -mx-1 rounded" onClick={() => setEditing(true)}>
          {display}
        </button>
      </Row>
    );
  }
  return (
    <Row label="评分">
      <div class="flex items-center gap-1">
        {[1, 2, 3, 4, 5].map(n => (
          <button
            onClick={async () => {
              await save(fm => ({ ...fm, rating: ratingToStars(n) }));
              setEditing(false);
            }}
            class="text-star hover:text-star px-0.5"
            title={`${n} 星`}
          >
            {n <= value ? '★' : '☆'}
          </button>
        ))}
        <button
          onClick={async () => {
            await save(fm => ({ ...fm, rating: null }));
            setEditing(false);
          }}
          class="ml-2 text-[10px] text-muted hover:text-danger"
          title="清空"
        >清空</button>
        <button onClick={() => setEditing(false)} class="ml-1 text-[10px] text-muted hover:text-secondary">取消</button>
      </div>
    </Row>
  );
}

function parseYear(s: string): number | null {
  const t = s.trim();
  if (!t) return null;
  const n = Number(t);
  return Number.isFinite(n) ? n : null;
}

function TextRow({
  label, value, field, parse, save,
}: {
  label: string;
  value: unknown;
  field: string;
  parse?: (s: string) => unknown;
  save: SaveFn;
}) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(value == null ? '' : String(value));
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (editing && inputRef.current) {
      inputRef.current.focus();
      inputRef.current.select();
    }
  }, [editing]);

  if (!editing) {
    const empty = value == null || value === '';
    return (
      <Row label={label}>
        <button
          class="text-left w-full hover:bg-surface-2 px-1 -mx-1 rounded text-secondary"
          onClick={() => { setDraft(value == null ? '' : String(value)); setEditing(true); }}
        >
          {empty ? <span class="text-muted">—</span> : String(value)}
          <span class="edit-hint inline-flex items-center text-muted ml-1"><Icon name="pencil" size={10} /></span>
        </button>
      </Row>
    );
  }

  const commit = async () => {
    const parsed = parse ? parse(draft) : (draft.trim() === '' ? null : draft);
    await save(fm => ({ ...fm, [field]: parsed }));
    setEditing(false);
  };

  return (
    <Row label={label}>
      <input
        ref={inputRef}
        type="text"
        value={draft}
        onInput={(e: JSX.TargetedEvent<HTMLInputElement>) => setDraft((e.target as HTMLInputElement).value)}
        onKeyDown={(e: JSX.TargetedKeyboardEvent<HTMLInputElement>) => {
          if (e.key === 'Enter') { e.preventDefault(); commit(); }
          if (e.key === 'Escape') { e.preventDefault(); setEditing(false); }
        }}
        onBlur={commit}
        class="w-full px-1.5 py-0.5 border border-accent rounded text-[12px] focus:outline-none focus:border-accent bg-accent-bg/40"
      />
    </Row>
  );
}

function AuthorRow({
  entry, backlinks, onOpen, save,
}: {
  entry: Entry;
  backlinks: { authorProfile?: Entry };
  onOpen: (entry: Entry) => void;
  save: SaveFn;
}) {
  const [editing, setEditing] = useState(false);
  if (editing || !entry.author) {
    return (
      <TextRow
        label="作者"
        value={entry.author}
        field="author"
        save={async (m) => { await save(m); setEditing(false); }}
      />
    );
  }
  return (
    <Row label="作者">
      <div class="flex items-center gap-1">
        {backlinks.authorProfile ? (
          <button onClick={() => onOpen(backlinks.authorProfile!)} class="text-accent-text hover:underline text-left flex-1 min-w-0 truncate">
            {entry.author}
          </button>
        ) : (
          <span class="flex-1 min-w-0 truncate">{entry.author}</span>
        )}
        <button onClick={() => setEditing(true)} class="text-muted hover:text-secondary px-1 inline-flex items-center" title="编辑"><Icon name="pencil" size={11} /></button>
      </div>
    </Row>
  );
}

function DoiRow({ value, save }: { value: string | null; save: SaveFn }) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(value ?? '');
  const inputRef = useRef<HTMLInputElement>(null);
  useEffect(() => { if (editing) inputRef.current?.focus(); }, [editing]);

  if (!editing) {
    return (
      <Row label="DOI">
        {value
          ? (
            <div class="flex items-center gap-1">
              <a href={`https://doi.org/${value}`} target="_blank" rel="noopener" class="text-accent-text hover:underline font-mono text-[11px] break-all flex-1 min-w-0">
                {value}
              </a>
              <button onClick={() => { setDraft(value); setEditing(true); }} class="text-muted hover:text-secondary px-1 inline-flex items-center" title="编辑"><Icon name="pencil" size={11} /></button>
            </div>
          )
          : (
            <button class="text-left w-full hover:bg-surface-2 px-1 -mx-1 rounded text-muted" onClick={() => { setDraft(''); setEditing(true); }}>
              — <span class="edit-hint inline-flex items-center text-muted ml-1"><Icon name="pencil" size={10} /></span>
            </button>
          )
        }
      </Row>
    );
  }
  const commit = async () => {
    const v = draft.trim() === '' ? null : draft.trim();
    await save(fm => ({ ...fm, doi: v }));
    setEditing(false);
  };
  return (
    <Row label="DOI">
      <input
        ref={inputRef}
        type="text"
        value={draft}
        onInput={(e: JSX.TargetedEvent<HTMLInputElement>) => setDraft((e.target as HTMLInputElement).value)}
        onKeyDown={(e: JSX.TargetedKeyboardEvent<HTMLInputElement>) => {
          if (e.key === 'Enter') { e.preventDefault(); commit(); }
          if (e.key === 'Escape') { e.preventDefault(); setEditing(false); }
        }}
        onBlur={commit}
        class="w-full px-1.5 py-0.5 border border-accent rounded font-mono text-[11px] focus:outline-none focus:border-accent bg-accent-bg/40"
      />
    </Row>
  );
}

function ThemesEditor({
  themes, onThemeClick, save, disabled,
}: {
  themes: string[];
  onThemeClick: (theme: string) => void;
  save: SaveFn;
  disabled: boolean;
}) {
  const [draft, setDraft] = useState('');
  const [adding, setAdding] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);
  useEffect(() => { if (adding) inputRef.current?.focus(); }, [adding]);

  const addOne = async (raw: string) => {
    const parts = raw.split(',').map(s => s.trim()).filter(Boolean);
    if (parts.length === 0) return;
    const next = [...themes];
    for (const p of parts) if (!next.includes(p)) next.push(p);
    await save(fm => ({ ...fm, themes: next }));
    setDraft('');
  };

  const remove = async (th: string) => {
    const next = themes.filter(x => x !== th);
    await save(fm => ({ ...fm, themes: next }));
  };

  return (
    <div>
      <div class="flex items-center justify-between mb-2">
        <div class="text-[11px] uppercase tracking-wider text-muted font-semibold">主题</div>
        <button
          onClick={() => setAdding(v => !v)}
          disabled={disabled}
          class="text-[10px] text-muted hover:text-primary px-1.5 py-0.5 rounded hover:bg-surface-2"
        >
          {adding ? '取消' : '+ 添加'}
        </button>
      </div>
      <div class="flex flex-wrap gap-1">
        {themes.map(th => (
          <span key={th} class="text-[11px] inline-flex items-center gap-0.5 rounded border border-base bg-page hover:bg-accent-bg hover:border-accent transition">
            <button onClick={() => onThemeClick(th)} class="px-1.5 py-0.5 hover:text-accent-text">{th}</button>
            <button onClick={() => remove(th)} title="移除" class="px-1 text-muted hover:text-danger border-l border-base inline-flex items-center"><Icon name="x" size={10} /></button>
          </span>
        ))}
        {themes.length === 0 && !adding && (
          <span class="text-[11px] text-muted">—</span>
        )}
      </div>
      {adding && (
        <div class="mt-2">
          <input
            ref={inputRef}
            type="text"
            value={draft}
            placeholder="新主题（逗号分隔可多个）"
            onInput={(e: JSX.TargetedEvent<HTMLInputElement>) => setDraft((e.target as HTMLInputElement).value)}
            onKeyDown={(e: JSX.TargetedKeyboardEvent<HTMLInputElement>) => {
              if (e.key === 'Enter') { e.preventDefault(); addOne(draft).then(() => setAdding(false)); }
              if (e.key === 'Escape') { e.preventDefault(); setAdding(false); setDraft(''); }
            }}
            class="w-full px-2 py-1 border border-accent rounded text-[12px] focus:outline-none focus:border-accent bg-accent-bg/40"
          />
        </div>
      )}
    </div>
  );
}
