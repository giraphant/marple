import { describe, expect, it } from 'vitest';
import {
  resolveOwner,
  routeByConfidence,
  scoreCandidate,
  titleAffinity,
  type CorpusBook,
  type MatchCandidate,
  type OriginalBook,
} from '../cn-matcher';

describe('scoreCandidate', () => {
  it('returns high confidence for matching original_title and author surname', () => {
    const candidate: MatchCandidate = {
      original_title: 'Deschooling Society',
      title_cn: '非學校化社會',
      authors: ['Ivan Illich'],
    };
    const original: OriginalBook = {
      title: 'Deschooling Society',
      authors: ['Ivan Illich'],
      year: 1971,
      isbn13: undefined,
    };

    const result = scoreCandidate(candidate, original);

    expect(result.score).toBe(70);
    expect(result.confidence).toBe('high');
    expect(result.signals).toEqual([
      'original_title exact match +50',
      'author surname match +20',
    ]);
  });

  it('returns medium confidence when ISBN agency and year proximity reinforce a contained title match', () => {
    const candidate: MatchCandidate = {
      original_title: 'Medical Nemesis',
      title_cn: '医学的限度',
      year: 1979,
      isbn: '978-7-108-00000-0',
    };
    const original: OriginalBook = {
      title: 'Limits to Medicine: Medical Nemesis: The Expropriation of Health',
      authors: ['Ivan Illich'],
      year: 1976,
      isbn13: '9780714529936',
    };

    const result = scoreCandidate(candidate, original);

    expect(result.score).toBe(55);
    expect(result.confidence).toBe('medium');
    expect(result.signals).toEqual([
      'original_title contains match +30',
      'year within 5 years +10',
      'Chinese publisher ISBN agency +15',
    ]);
  });

  it('returns low confidence for a partial title match only', () => {
    const candidate: MatchCandidate = {
      original_title: 'Media',
      title_cn: '理解媒介',
    };
    const original: OriginalBook = {
      title: 'Understanding Media',
      authors: ['Marshall McLuhan'],
      year: 1964,
    };

    const result = scoreCandidate(candidate, original);

    expect(result.score).toBe(30);
    expect(result.confidence).toBe('low');
    expect(result.signals).toEqual(['original_title contains match +30']);
  });

  it('returns none for a completely unrelated candidate', () => {
    const candidate: MatchCandidate = {
      original_title: 'The Great Gatsby',
      title_cn: '了不起的盖茨比',
      authors: ['F. Scott Fitzgerald'],
      year: 1925,
      isbn: '978-0-7432-7356-5',
    };
    const original: OriginalBook = {
      title: 'The Body Multiple',
      authors: ['Annemarie Mol'],
      year: 2002,
      isbn13: '9780822329029',
    };

    const result = scoreCandidate(candidate, original);

    expect(result.score).toBe(0);
    expect(result.confidence).toBe('none');
    expect(result.signals).toEqual([]);
  });

  it('applies the _weak-style penalty when original_title is missing and no signals match', () => {
    const candidate: MatchCandidate = {
      title_cn: '弱候选',
    };
    const original: OriginalBook = {
      title: 'Tools for Conviviality',
      authors: ['Ivan Illich'],
      year: 1973,
    };

    const result = scoreCandidate(candidate, original);

    expect(result.score).toBe(-20);
    expect(result.confidence).toBe('none');
    expect(result.signals).toEqual(['missing original_title -20']);
  });

  it('recognises Taiwan (978-957) and Hong Kong (978-988) ISBN agencies as Chinese editions', () => {
    const base: MatchCandidate = {
      original_title: 'Deschooling Society',
      title_cn: '非學校化社會',
      authors: ['Ivan Illich'],
    };
    const original: OriginalBook = { title: 'Deschooling Society', authors: ['Ivan Illich'], year: 1971 };

    const taiwan = scoreCandidate({ ...base, isbn: '978-957-551-703-8' }, original);
    expect(taiwan.signals).toContain('Chinese publisher ISBN agency +15');

    const hongKong = scoreCandidate({ ...base, isbn: '9789620000000' }, original);
    expect(hongKong.signals).toContain('Chinese publisher ISBN agency +15');
  });

  it('does not award the ISBN signal to a non-Chinese agency prefix', () => {
    const result = scoreCandidate(
      { original_title: 'Understanding Media', title_cn: '理解媒介', isbn: '9780262631594' },
      { title: 'Understanding Media', year: 1964 },
    );
    expect(result.signals).not.toContain('Chinese publisher ISBN agency +15');
  });

  it('still scores a no-ISBN original book from title and author signals', () => {
    const candidate: MatchCandidate = {
      original_title: 'Shadow Work',
      title_cn: '影子工作',
      authors: ['Ivan Illich'],
      year: 1981,
      isbn: '978-7-0000-0000-1',
    };
    const original: OriginalBook = {
      title: 'Shadow Work',
      authors: ['Ivan Illich'],
      year: 1981,
    };

    const result = scoreCandidate(candidate, original);

    expect(result.score).toBe(95);
    expect(result.confidence).toBe('high');
    expect(result.signals).toEqual([
      'original_title exact match +50',
      'author surname match +20',
      'year within 5 years +10',
      'Chinese publisher ISBN agency +15',
    ]);
  });
});

describe('titleAffinity', () => {
  it('is 1 for identical or subtitle-containing titles, lower for partial overlap', () => {
    expect(titleAffinity('The Body and Society', 'The Body and Society')).toBe(1);
    expect(titleAffinity('The Body and Society', 'The Body and Society: Explorations in Social Theory')).toBe(1);
    expect(titleAffinity('Cognition in the Wild', 'Culture and Inference: A Trobriand Case Study')).toBeLessThan(0.34);
    // A French original does not match the English translation's title.
    expect(titleAffinity("Nous n'avons jamais été modernes", 'We Have Never Been Modern')).toBeLessThan(0.34);
  });
});

describe('resolveOwner', () => {
  const corpus: CorpusBook[] = [
    { slug: 'turner-body-and-society-2008', title: 'The Body and Society: Explorations in Social Theory' },
    { slug: 'hutchins-cognition-in-the-wild-1995', title: 'Cognition in the Wild' },
    { slug: 'turner-regulating-bodies-1992', title: 'Regulating Bodies: Essays in Medical Sociology' },
  ];

  it('attributes a candidate to the book its original_title actually names', () => {
    // Candidate scraped for "Regulating Bodies" but whose 原作名 is "The Body and Society"
    // really belongs to turner-body-and-society, not the book it was cached under.
    const owner = resolveOwner('The Body and Society', corpus);
    expect(owner?.slug).toBe('turner-body-and-society-2008');
    expect(owner?.score).toBe(1);
  });

  it('returns no strong owner for a foreign-language original not in the corpus', () => {
    const owner = resolveOwner("Nous n'avons jamais été modernes", corpus);
    expect(owner === null || owner.score < 0.6).toBe(true);
  });
});

describe('routeByConfidence', () => {
  it('auto-writes high, queues medium and low for review, and drops only none', () => {
    expect(routeByConfidence('high')).toBe('write');
    expect(routeByConfidence('medium')).toBe('review');
    expect(routeByConfidence('low')).toBe('review');
    expect(routeByConfidence('none')).toBe('skip');
  });
});
