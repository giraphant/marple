import { useMemo, useState, useRef, useEffect } from 'preact/hooks';
import type { JSX, ComponentChildren } from 'preact';
import type { Entry } from '../types';
import { splitAuthors } from '../wiki';
import { patchFrontmatter, applyFmToEntry } from '../api';
import { ratingToStars } from '../frontmatter';
import { MiniRow } from './MiniRow';
import { Icon } from './Icon';

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
    const out: { works?: Entry[]; siblings?: Entry[]; similar?: Entry[]; authorProfile?: Entry } = {};
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
        .sort((a, b) => (b.rating_score || 0) - (a.rating_score || 0))
        .slice(0, 8);

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
    <div class="p-5 space-y-5 text-[12px] text-stone-700">
      {err && (
        <div class="text-[11px] px-2 py-1 rounded bg-red-50 text-red-700 border border-red-200">
          保存失败：{err}
        </div>
      )}

      {entry.type === 'note' && annotatesTarget && (
        <div class="text-[11px] px-2 py-1.5 rounded bg-rose-50 text-rose-800 border border-rose-200">
          批注于 <button onClick={() => onOpen(annotatesTarget)} class="font-medium underline hover:text-rose-900">
            {annotatesTarget.title || annotatesTarget.path.split('/').pop()}
          </button>
        </div>
      )}

      {(entry.type === 'paper-analysis' || entry.type === 'book-overview') && (
        <ActionsRow entry={entry} />
      )}
      <dl class={`space-y-2 ${saving ? 'opacity-60 pointer-events-none' : ''}`}>
        <RatingRow value={entry.rating_score} save={save} />
        <TextRow label="年份" value={entry.year} field="year" parse={parseYear} save={save} />
        <AuthorRow entry={entry} backlinks={backlinks} onOpen={onOpen} save={save} />
        <TextRow label="来源" value={entry.source} field="source" save={save} />
        <DoiRow value={entry.doi} save={save} />
        <TextRow label="Topic" value={entry.topic} field="topic" save={save} />
        {entry.chapters_analyzed != null && (
          <div class="grid grid-cols-[60px_1fr] gap-2">
            <dt class="text-stone-500 text-[11px] pt-0.5">章节数</dt>
            <dd class="min-w-0 tabular-nums">{entry.chapters_analyzed}</dd>
          </div>
        )}
      </dl>

      <ThemesEditor themes={themes} onThemeClick={onThemeClick} save={save} disabled={saving} />

      {entry.type !== 'note' && (
        <div>
          <div class="flex items-center justify-between mb-1">
            <div class="text-[11px] uppercase tracking-wider text-stone-500 font-semibold">
              我的批注{myAnnotations.length > 0 && ` (${myAnnotations.length})`}
            </div>
            <button
              onClick={handleCreate}
              disabled={creatingNote}
              class="text-[10px] text-rose-700 hover:text-rose-900 px-1.5 py-0.5 rounded hover:bg-rose-50 border border-rose-200 disabled:opacity-50"
            >
              {creatingNote ? '创建中…' : '+ 新建批注'}
            </button>
          </div>
          {myAnnotations.length > 0 ? (
            <div class="space-y-0.5">
              {myAnnotations.map(n => <MiniRow entry={n} onClick={onOpen} key={n.path} />)}
            </div>
          ) : (
            <div class="text-[11px] text-stone-400 pl-2">—</div>
          )}
        </div>
      )}

      {backlinks.works && backlinks.works.length > 0 && (
        <Section title={`作品 (${backlinks.works.length})`}>
          {backlinks.works.slice(0, 30).map(w => <MiniRow entry={w} onClick={onOpen} key={w.path} />)}
          {backlinks.works.length > 30 && (
            <div class="text-[10px] text-stone-400 pl-2">+{backlinks.works.length - 30} 条</div>
          )}
        </Section>
      )}

      {backlinks.siblings && backlinks.siblings.length > 0 && (
        <Section title="同作者其他">
          {backlinks.siblings.map(w => <MiniRow entry={w} onClick={onOpen} key={w.path} />)}
        </Section>
      )}

      {backlinks.similar && backlinks.similar.length > 0 && (
        <Section title="同主题相似">
          {backlinks.similar.map(w => <MiniRow entry={w} onClick={onOpen} key={w.path} />)}
        </Section>
      )}
    </div>
  );
}

// Build a markdown-style citation string for paper / book entries.
// Format: "Author (year). *Title*. Source. https://doi.org/DOI"
// Missing fields are skipped gracefully.
function buildCitation(entry: Entry): string {
  const parts: string[] = [];
  const author = entry.author?.trim();
  const year = entry.year != null ? String(entry.year).trim() : '';
  const title = entry.title?.trim();
  const source = entry.source?.trim();
  const doi = entry.doi?.trim();

  if (author && year)      parts.push(`${author} (${year}).`);
  else if (author)         parts.push(`${author}.`);
  else if (year)           parts.push(`(${year}).`);

  if (title)               parts.push(`*${title}*.`);
  if (source)              parts.push(`${source}.`);
  if (doi)                 parts.push(`https://doi.org/${doi}`);

  return parts.join(' ').replace(/\s+/g, ' ').trim();
}

function ActionsRow({ entry }: { entry: Entry }) {
  const [copied, setCopied] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const copyCitation = async () => {
    setErr(null);
    const text = buildCitation(entry);
    if (!text) { setErr('引用字段不全（缺 author/title/year/source/doi）'); return; }
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch (e) {
      setErr(e instanceof Error ? e.message : '复制失败');
    }
  };

  const openPdf = () => {
    if (!entry.pdf_slug) return;
    window.open(`/sources/${entry.pdf_slug}.pdf`, '_blank', 'noopener');
  };

  return (
    <div class="flex items-center gap-2 -mt-1 text-[11px] flex-wrap">
      <button
        onClick={copyCitation}
        class="px-2 py-1 rounded border border-stone-200 bg-white hover:border-stone-400 text-stone-700 hover:text-stone-900 transition"
        title={`复制 markdown 引用\n\n预览：${buildCitation(entry).slice(0, 200)}`}
      >
        {copied ? '✓ 已复制' : '复制引用'}
      </button>
      {entry.has_pdf && entry.pdf_slug && (
        <button
          onClick={openPdf}
          class="px-2 py-1 rounded border border-stone-200 bg-white hover:border-stone-400 text-stone-700 hover:text-stone-900 transition"
          title={`打开 sources/${entry.pdf_slug}.pdf`}
        >打开 PDF</button>
      )}
      {err && <span class="text-red-600 text-[10px]">{err}</span>}
    </div>
  );
}

function Section({ title, children }: { title: string; children: ComponentChildren }) {
  return (
    <div>
      <div class="text-[11px] uppercase tracking-wider text-stone-500 font-semibold mb-1">{title}</div>
      <div class="space-y-0.5">{children}</div>
    </div>
  );
}

function Row({ label, children }: { label: string; children: ComponentChildren }) {
  return (
    <div class="editable-row grid grid-cols-[60px_1fr] gap-2 items-start">
      <dt class="text-stone-500 text-[11px] pt-0.5">{label}</dt>
      <dd class="min-w-0">{children}</dd>
    </div>
  );
}

function RatingRow({ value, save }: { value: number; save: SaveFn }) {
  const display = value > 0 ? '★'.repeat(value) : <span class="text-stone-400">—</span>;
  const [editing, setEditing] = useState(false);
  if (!editing) {
    return (
      <Row label="评分">
        <button class="text-amber-600 text-left hover:bg-stone-100 px-1 -mx-1 rounded" onClick={() => setEditing(true)}>
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
            class="text-amber-600 hover:text-amber-800 px-0.5"
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
          class="ml-2 text-[10px] text-stone-400 hover:text-red-600"
          title="清空"
        >清空</button>
        <button onClick={() => setEditing(false)} class="ml-1 text-[10px] text-stone-400 hover:text-stone-700">取消</button>
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
          class="text-left w-full hover:bg-stone-100 px-1 -mx-1 rounded text-stone-700"
          onClick={() => { setDraft(value == null ? '' : String(value)); setEditing(true); }}
        >
          {empty ? <span class="text-stone-400">—</span> : String(value)}
          <span class="edit-hint inline-flex items-center text-stone-400 ml-1"><Icon name="pencil" size={10} /></span>
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
        class="w-full px-1.5 py-0.5 border border-amber-300 rounded text-[12px] focus:outline-none focus:border-amber-500 bg-amber-50/30"
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
          <button onClick={() => onOpen(backlinks.authorProfile!)} class="text-sky-700 hover:underline text-left flex-1 min-w-0 truncate">
            {entry.author}
          </button>
        ) : (
          <span class="flex-1 min-w-0 truncate">{entry.author}</span>
        )}
        <button onClick={() => setEditing(true)} class="text-stone-400 hover:text-stone-700 px-1 inline-flex items-center" title="编辑"><Icon name="pencil" size={11} /></button>
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
              <a href={`https://doi.org/${value}`} target="_blank" rel="noopener" class="text-sky-700 hover:underline font-mono text-[11px] break-all flex-1 min-w-0">
                {value}
              </a>
              <button onClick={() => { setDraft(value); setEditing(true); }} class="text-stone-400 hover:text-stone-700 px-1 inline-flex items-center" title="编辑"><Icon name="pencil" size={11} /></button>
            </div>
          )
          : (
            <button class="text-left w-full hover:bg-stone-100 px-1 -mx-1 rounded text-stone-400" onClick={() => { setDraft(''); setEditing(true); }}>
              — <span class="edit-hint inline-flex items-center text-stone-400 ml-1"><Icon name="pencil" size={10} /></span>
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
        class="w-full px-1.5 py-0.5 border border-amber-300 rounded font-mono text-[11px] focus:outline-none focus:border-amber-500 bg-amber-50/30"
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
        <div class="text-[11px] uppercase tracking-wider text-stone-500 font-semibold">主题</div>
        <button
          onClick={() => setAdding(v => !v)}
          disabled={disabled}
          class="text-[10px] text-stone-500 hover:text-stone-800 px-1.5 py-0.5 rounded hover:bg-stone-100"
        >
          {adding ? '取消' : '+ 添加'}
        </button>
      </div>
      <div class="flex flex-wrap gap-1">
        {themes.map(th => (
          <span key={th} class="text-[11px] inline-flex items-center gap-0.5 rounded border border-stone-200 bg-stone-50 hover:bg-amber-50 hover:border-amber-300 transition">
            <button onClick={() => onThemeClick(th)} class="px-1.5 py-0.5 hover:text-amber-800">{th}</button>
            <button onClick={() => remove(th)} title="移除" class="px-1 text-stone-400 hover:text-red-600 border-l border-stone-200 inline-flex items-center"><Icon name="x" size={10} /></button>
          </span>
        ))}
        {themes.length === 0 && !adding && (
          <span class="text-[11px] text-stone-400">—</span>
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
            class="w-full px-2 py-1 border border-amber-300 rounded text-[12px] focus:outline-none focus:border-amber-500 bg-amber-50/30"
          />
        </div>
      )}
    </div>
  );
}
