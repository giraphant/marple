/**
 * Split a vault markdown body into segments keyed by H2.
 *
 * The vault SPEC v0.2 §4 treats every `## H2` in an entry's body as a
 * typed block (paragraph / table / blockquote-list / h3-project-tabs / …).
 * The reader uses this splitter so it can route each section to a
 * specialised renderer when the H2 + content shape match a known typed
 * block, and fall back to plain markdown otherwise.
 *
 * Notes:
 * - The text BEFORE the first H2 is returned as a `'prelude'` segment.
 *   That's where the H1 title + intro paragraph usually live; we don't
 *   want to touch it.
 * - H3 and deeper headings stay INSIDE their parent H2 segment — typed
 *   renderers like `h3-project-tabs` peel them off internally.
 * - Code fences (``` … ```) are respected: a `##` inside a fence does
 *   NOT start a new section.
 */

export type Segment =
  | { kind: 'prelude'; content: string }
  | { kind: 'h2'; title: string; content: string };

export function splitSections(body: string): Segment[] {
  const lines = body.split(/\r?\n/);
  const segments: Segment[] = [];
  let currentTitle: string | null = null;
  let buffer: string[] = [];
  let inFence = false;
  let fenceMarker = '';

  const flush = () => {
    if (buffer.length === 0 && currentTitle === null) return;
    const content = buffer.join('\n');
    if (currentTitle === null) segments.push({ kind: 'prelude', content });
    else segments.push({ kind: 'h2', title: currentTitle, content });
    buffer = [];
  };

  for (const line of lines) {
    // Toggle fenced-code state. Treat any ``` or ~~~ as a fence marker.
    const fenceMatch = line.match(/^(```+|~~~+)/);
    if (fenceMatch) {
      if (!inFence) { inFence = true; fenceMarker = fenceMatch[1]; }
      else if (line.startsWith(fenceMarker)) { inFence = false; fenceMarker = ''; }
    }
    const h2Match = !inFence ? line.match(/^##\s+(.+?)\s*$/) : null;
    if (h2Match && !line.startsWith('### ')) {
      flush();
      currentTitle = h2Match[1].trim();
      continue;
    }
    buffer.push(line);
  }
  flush();
  return segments;
}

/** Parse a markdown table into header + row arrays. Returns null when the
 *  block doesn't look like a GFM pipe table.
 *  Header cells are trimmed; row cells keep inline markdown markup so the
 *  renderer can pass them through marked.parseInline if needed. */
export function parseMarkdownTable(text: string): { headers: string[]; rows: string[][] } | null {
  const lines = text.split(/\r?\n/);
  // Find the header row (first line containing `|`) and a separator row
  // immediately after it whose cells are all dashes/colons.
  let headerIdx = -1;
  for (let i = 0; i < lines.length - 1; i++) {
    if (lines[i].includes('|') && /^\s*\|?\s*:?-{2,}/.test(lines[i + 1])) {
      headerIdx = i;
      break;
    }
  }
  if (headerIdx < 0) return null;

  const parseCells = (line: string): string[] => {
    let s = line.trim();
    if (s.startsWith('|')) s = s.slice(1);
    if (s.endsWith('|')) s = s.slice(0, -1);
    return s.split('|').map(c => c.trim());
  };

  const headers = parseCells(lines[headerIdx]);
  const rows: string[][] = [];
  for (let i = headerIdx + 2; i < lines.length; i++) {
    const line = lines[i];
    if (!line.trim()) break;                 // blank line ends the table
    if (!line.includes('|')) break;
    const cells = parseCells(line);
    // Pad short rows / clip long rows to header width so renderers can index by column.
    while (cells.length < headers.length) cells.push('');
    rows.push(cells.slice(0, headers.length));
  }
  return rows.length > 0 ? { headers, rows } : null;
}
