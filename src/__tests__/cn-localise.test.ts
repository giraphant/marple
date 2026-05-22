import { describe, expect, it } from 'vitest';
import * as YAML from 'yaml';
import { parse } from 'yaml';
import { applyZhLocalisation, type ZhLocalisation } from '../cn-localise';

const apply = (text: string, loc: ZhLocalisation, opts?: { force?: boolean }) =>
  applyZhLocalisation(YAML, text, loc, opts);

const LOC: ZhLocalisation = {
  title: '气味哲学',
  translator: '某译者',
  publisher: '某出版社',
  year: 2023,
  isbn: '9787100000000',
  original_title: 'Smellosophy',
  douban_url: 'https://book.douban.com/subject/123456/',
  ratings_count: 42,
};

const NO_LOC = `---
type: book
title: 'Smellosophy: What the Nose Tells the Mind'
authors: [A. S. Barwich]
year: 2020
publisher: Harvard University Press
isbn: "9780674983694"
themes: [olfaction, perception, neuroscience]
---

# Smellosophy

Body text, with a colon: preserved.
`;

function frontmatter(text: string): string {
  return text.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n/)![1];
}
function body(text: string): string {
  return text.match(/^---\r?\n[\s\S]*?\r?\n---\r?\n([\s\S]*)$/)![1];
}

describe('applyZhLocalisation', () => {
  it('inserts localisations.zh and round-trips to the input localisation', () => {
    const next = apply(NO_LOC, LOC)!;
    expect(next).not.toBeNull();
    const fm = parse(frontmatter(next));
    expect(fm.localisations.zh).toHaveLength(1);
    expect(fm.localisations.zh[0]).toEqual(LOC);
  });

  it('leaves every untouched frontmatter line and the body byte-for-byte intact', () => {
    const next = apply(NO_LOC, LOC)!;
    // Untouched scalars keep their original quoting; flow arrays keep their style.
    expect(next).toContain("title: 'Smellosophy: What the Nose Tells the Mind'");
    expect(next).toContain('authors: [A. S. Barwich]');
    expect(next).toContain('themes: [olfaction, perception, neuroscience]');
    expect(next).toContain('isbn: "9780674983694"');
    // Body is preserved exactly, including its own colon.
    expect(body(next)).toBe(body(NO_LOC));
  });

  it('is idempotent: refuses to clobber an existing zh entry without force', () => {
    const once = apply(NO_LOC, LOC)!;
    const twice = apply(once, { ...LOC, title: '另一个版本' });
    expect(twice).toBeNull();
  });

  it('replaces zh[0] but keeps later entries when force is set', () => {
    const once = apply(NO_LOC, LOC)!;
    // Hand-add a second curated entry to confirm force only swaps the head.
    const withTwo = once.replace(
      `    - title: ${LOC.title}`,
      `    - title: 旧版\n      publisher: 旧社\n    - title: ${LOC.title}`,
    );
    const forced = apply(withTwo, { ...LOC, title: '新版' }, { force: true })!;
    const fm = parse(frontmatter(forced));
    expect(fm.localisations.zh).toHaveLength(2);
    expect(fm.localisations.zh[0].title).toBe('新版');
    expect(fm.localisations.zh[1].title).toBe(LOC.title);
  });

  it('returns null for text without a frontmatter fence', () => {
    expect(apply('# just a heading\n', LOC)).toBeNull();
  });
});
