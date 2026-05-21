import { describe, it, expect } from 'vitest';
import type { Entry } from './types';
import { deriveBibliographicInfo } from './bibliographic-info';

function entry(overrides: Partial<Entry>): Entry {
  return {
    path: 'vault/books/example/00-overview.md',
    type: 'book-overview',
    book: null,
    title: null,
    author: null,
    year: null,
    rating: null,
    rating_score: 0,
    themes: null,
    topic: null,
    source: null,
    doi: null,
    chapters_analyzed: null,
    annotates: null,
    created: null,
    preview: '',
    ...overrides,
  };
}

describe('deriveBibliographicInfo', () => {
  it('shows chapter title aliases and parent book metadata', () => {
    const overview = entry({
      path: 'vault/books/marks-skin-of-the-film-2000/00-overview.md',
      type: 'book-overview',
      title: 'The Skin of the Film',
      publisher: 'Duke University Press',
      isbn: '9780822381372',
      doi: '10.1215/9780822381372',
      source: 'book',
    });
    const chapter = entry({
      path: 'vault/books/marks-skin-of-the-film-2000/ch03-memory-of-touch.md',
      type: 'chapter-summary',
      book: 'marks-skin-of-the-film-2000',
      title: '第3章 触觉的记忆',
      title_cn: '触觉的记忆',
      title_en: 'The Memory of Touch',
      publisher: null,
      isbn: null,
      doi: null,
    });

    const info = deriveBibliographicInfo(chapter, [overview, chapter]);

    expect(info.book?.path).toBe(overview.path);
    expect(info.rows).toContainEqual({ label: '中文题名', value: '触觉的记忆' });
    expect(info.rows).toContainEqual({ label: '英文题名', value: 'The Memory of Touch' });
    expect(info.rows).toContainEqual({ label: '出版社', value: 'Duke University Press' });
    expect(info.rows).toContainEqual({ label: '图书号', value: '9780822381372' });
    expect(info.rows).toContainEqual({ label: 'DOI', value: '10.1215/9780822381372' });
    expect(info.rows.some(row => row.label === '来源')).toBe(false);
  });

  it('skips duplicate title aliases', () => {
    const overview = entry({
      title: 'Atlas of AI',
      title_en: 'Atlas of AI',
      title_cn: 'AI地图集',
      publisher: 'Yale University Press',
      source: 'Yale University Press',
    });

    const info = deriveBibliographicInfo(overview, [overview]);

    expect(info.book).toBeNull();
    expect(info.rows).toContainEqual({ label: '中文题名', value: 'AI地图集' });
    expect(info.rows.some(row => row.label === '英文题名')).toBe(false);
    expect(info.rows.some(row => row.label === '来源')).toBe(false);
  });

  it('shows Chinese translation as a Douban link', () => {
    const overview = entry({
      title: 'Deschooling Society',
      translation_title_cn: '非學校化社會',
      translation_douban_url: 'https://book.douban.com/subject/1997483/',
    });

    const info = deriveBibliographicInfo(overview, [overview]);

    expect(info.rows).toContainEqual({
      label: '中文版',
      value: '非學校化社會',
      href: 'https://book.douban.com/subject/1997483/',
    });
  });
});
