// Surgical frontmatter writer for Chinese-edition localisations.
//
// YAML is dependency-injected (type-only import, erased at build time) so the
// CLI in reader/scripts can load this module through its lightweight runtime
// TypeScript transpiler, which can only handle modules with no runtime imports.
import type * as YAMLNS from 'yaml';

type YamlModule = typeof YAMLNS;

export type ZhLocalisation = {
  title?: string;
  translator?: string;
  publisher?: string;
  year?: number;
  isbn?: string;
  original_title?: string;
  douban_url?: string;
  ratings_count?: number;
};

const FENCE = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/;

/**
 * Set frontmatter `localisations.zh[0]` to `localisation`, leaving every other
 * frontmatter line and the document body byte-for-byte unchanged.
 *
 * Uses YAML.parseDocument so untouched scalars keep their original quoting and
 * collections keep their original style. A full `new Document(fm)` rebuild
 * reformats the whole block (single→double quotes, flow padding) and even
 * drops leading zeros on unquoted ISBNs — verified to churn 200+ vault files.
 *
 * Returns the new file text, or null when a zh localisation already exists and
 * `force` is not set (idempotent: never clobbers a curated entry by default),
 * or when the text has no frontmatter fence.
 */
export function applyZhLocalisation(
  YAML: YamlModule,
  text: string,
  localisation: ZhLocalisation,
  { force = false }: { force?: boolean } = {},
): string | null {
  const match = text.match(FENCE);
  if (!match) return null;
  const [, fmText, body] = match;
  const doc = YAML.parseDocument(fmText);

  const existing = doc.getIn(['localisations', 'zh']);
  const existingItems = YAML.isSeq(existing) ? existing.items : [];
  const hasExisting = existingItems.length > 0 || (existing != null && !YAML.isSeq(existing));
  if (hasExisting && !force) return null;

  const items = force ? [localisation, ...existingItems.slice(1)] : [localisation];
  const nextZh = doc.createNode(items);
  if (YAML.isSeq(nextZh)) nextZh.flow = false;
  doc.setIn(['localisations', 'zh'], nextZh);

  const nextFm = doc
    .toString({ lineWidth: 0, nullStr: '', singleQuote: true, flowCollectionPadding: false })
    .replace(/\n$/, '');
  return `---\n${nextFm}\n---\n${body}`;
}
