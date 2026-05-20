/**
 * QUA-57: extract a heading outline from markdown body text.
 *
 * Used for the editor-mode 目录 tab, where each heading maps to a source line so
 * clicking scrolls the CodeMirror editor. (Read mode builds its outline from the
 * rendered DOM instead, since BodyView routes some sections through typed
 * renderers — see the design spec.) Fenced code blocks are skipped so a `#`
 * comment inside ```code``` isn't mistaken for a heading.
 */

export interface OutlineHeading {
  /** 1–6. */
  level: number;
  text: string;
  /** 1-based source line number. */
  line: number;
}

const FENCE_RE = /^(\s{0,3})(```+|~~~+)/;
const HEADING_RE = /^(#{1,6})\s+(.+?)\s*#*\s*$/;

export function extractHeadings(markdown: string): OutlineHeading[] {
  const lines = markdown.split('\n');
  const out: OutlineHeading[] = [];
  let inFence = false;
  let fenceChar = '';
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const fence = line.match(FENCE_RE);
    if (fence) {
      const ch = fence[2][0];
      if (!inFence) { inFence = true; fenceChar = ch; }
      else if (ch === fenceChar) { inFence = false; fenceChar = ''; }
      continue;
    }
    if (inFence) continue;
    const m = line.match(HEADING_RE);
    if (m) out.push({ level: m[1].length, text: m[2].trim(), line: i + 1 });
  }
  return out;
}
