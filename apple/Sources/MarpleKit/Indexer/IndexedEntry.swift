// MARK: - IndexedEntry
//
// One struct per row in the `entries` SQLite table, plus the `BuildOutcome`
// enum and the `buildIndexedEntry` free function.
//
// Mirrors `IndexedEntry` struct (:80-116), `BuildOutcome` enum (:120-128), and
// `build_indexed_entry` function (:132-244) in
// `rust/reader-core/src/indexer.rs` — read those line ranges as the spec.

// MARK: - IndexedEntry struct

/// One row in the `entries` table plus the FTS support columns.
///
/// Field names use Swift camelCase; the mapping to `entries` columns is
/// documented inline.  The field set matches the Rust `IndexedEntry` struct
/// exactly, including `bodyText` (column `body_text`) and `searchText`
/// (column `search_text` / used for entry_text + entry_trigram).
public struct IndexedEntry: Sendable, Equatable {

    // MARK: Primary key

    /// Workspace-relative path (e.g. `"vault/papers/smith-dogs-2019.md"`).
    /// Column: `path`.
    public var path: String

    // MARK: Classification

    /// Canonical type string (output of `canonicalType`), e.g. `"paper-analysis"`.
    /// Column: `type`.
    public var entryType: String

    /// For `chapter-summary` entries only: first path component after
    /// `"vault/books/"`.  Column: `book`.
    public var book: String?

    // MARK: Titles

    /// Primary display title after `stripWiki`.  Column: `title`.
    public var title: String?

    /// English title from `title_en` / `chapter_title_en`.  Column: `title_en`.
    public var titleEn: String?

    /// Chinese title from frontmatter or (book-overview only) first Chinese H1.
    /// Column: `title_cn`.
    public var titleCn: String?

    // MARK: Attribution

    /// Flattened author string (sequence joined with `", "`, or scalar).
    /// Column: `author`.
    public var author: String?

    // MARK: Year / rating

    /// JSON serialization of the `year` field (e.g. `"2019"` or `"\"2019\""`).
    /// Column: `year` (stored as TEXT in entries; the Rust stores Option<JsonValue>).
    public var yearJSON: String?

    /// JSON serialization of the `rating` field (truthy only).
    /// Column: `rating`.
    public var ratingJSON: String?

    /// Numeric rating derived from `ratingScore` helper.
    /// Column: `rating_score`.
    public var ratingScore: Double

    /// Theme tags as a string array.  Column: `themes` (stored as JSON array TEXT).
    public var themes: [String]?

    // MARK: Bibliographic metadata

    /// Column: `topic`.
    public var topic: String?

    /// Column: `source`.
    public var source: String?

    /// Column: `doi`.
    public var doi: String?

    /// Column: `publisher`.
    public var publisher: String?

    /// Column: `isbn`.
    public var isbn: String?

    // MARK: Translation / localisation

    /// Column: `translation_title_cn`.
    public var translationTitleCn: String?

    /// Column: `translation_douban_url`.
    public var translationDoubanURL: String?

    // MARK: Chapter / reference links

    /// Number of chapters analyzed (for book-overview).  Column: `chapters_analyzed`.
    public var chaptersAnalyzed: Int64?

    /// Path/slug of the entry this one annotates.  Column: `annotates`.
    public var annotates: String?

    /// Free-text creation date from frontmatter.  Column: `created`.
    public var created: String?

    // MARK: Source PDF

    /// Slug used to locate the source PDF.  Column: `pdf_slug`.
    public var pdfSlug: String?

    /// Whether a matching source PDF was found.  Column: `has_pdf`.
    public var hasPDF: Bool

    // MARK: Timestamps

    /// File modification time in epoch-ms (nil if unavailable).  Column: `mtime`.
    public var mtime: Int64?

    // MARK: Content / FTS

    /// Preview text (≤ 800 Unicode scalars).  Column: `preview`.
    public var preview: String

    /// Unicode scalar count of the normalized body.  Column: `body_len`.
    public var bodyLen: Int64

    /// Epoch-ms of the file's first git commit; 0 if unknown.
    /// Set to 0 here; the full-build caller overwrites it from `gitAddedDates`.
    /// Column: `added`.
    public var added: Int64

    /// Normalized body text (CRLF→LF, trimmed lines, no blank lines).
    /// Column: `body_text` (also the source for `entry_text.search_text` and
    /// `entry_trigram.text`).
    public var bodyText: String

    /// Composite search string from rel + titles + author + publisher + isbn +
    /// translationTitleCn + normalized body.  Stored in `entry_text.search_text`
    /// and `entry_trigram.text`.
    public var searchText: String
}

// MARK: - BuildOutcome enum

/// Result of parsing one markdown file.  Mirrors Rust `BuildOutcome` (:120-128).
public enum BuildOutcome: Sendable, Equatable {

    /// Successfully parsed into a full index row.
    case indexed(IndexedEntry)

    /// Has a frontmatter fence but no `type` key.
    case skippedNoType

    /// Has a `type` value that `canonicalType` maps to nil (i.e. `""` or `"A"`).
    case skippedUnknownType

    /// No frontmatter fence at all — a plain markdown file.
    case skipped
}

// MARK: - buildIndexedEntry

/// Parse a single markdown file text into a `BuildOutcome`.
///
/// Mirrors `build_indexed_entry` (:132-244) in `rust/reader-core/src/indexer.rs`.
///
/// - Parameters:
///   - text:        Full file contents (UTF-8 string).
///   - rel:         Workspace-relative path (e.g. `"vault/papers/x.md"`).
///   - fileStem:    Filename without the `.md` extension.
///   - sourceSlugs: Set of PDF stem names from the `sources/` directory.
///   - mtimeMs:     File modification time in epoch-ms, or nil.
///
/// `added` is always initialised to 0; the full-build caller sets it later
/// from `gitAddedDates`.
public func buildIndexedEntry(
    text: String,
    rel: String,
    fileStem: String,
    sourceSlugs: Set<String>,
    mtimeMs: Int64?
) -> BuildOutcome {

    // 1. Fence detection — mirrors `parse_file` / Rust's fence check.
    //    `Frontmatter.split` returns nil frontmatter when there is no `---` fence.
    let (rawFrontmatter, body) = Frontmatter.split(text)
    guard let rawFrontmatter else {
        return .skipped
    }

    // 2. Parse frontmatter YAML into an ordered mapping.
    let frontmatter = YamlFrontmatter.parseMapping(rawFrontmatter)

    // 3. type key required.
    guard let rawType = truthyText(frontmatter, "type") else {
        // field("type") returns nil OR the value is empty string
        // Mirror Rust: field_text returns None when field is missing or null.
        // However we also need to handle the case where `type` key exists but
        // value is null/empty — that still counts as SkippedNoType per Rust logic
        // (field_text returns None for null/empty).
        if field(frontmatter, "type") != nil {
            // key exists but value is falsy/null: no usable type string → SkippedNoType
            return .skippedNoType
        }
        return .skippedNoType
    }

    // 4. Canonical type mapping.
    guard let entryType = canonicalType(rawType) else {
        return .skippedUnknownType
    }

    // 5. Derive structural fields.

    // book: only for chapter-summary
    let book: String? = entryType == "chapter-summary" ? bookSlug(rel) : nil

    // pdf_slug
    let pdfSlugValue: String? = pdfSlug(type: entryType, rel: rel, fileStem: fileStem)

    // has_pdf
    let hasPDFValue: Bool = pdfSlugValue.map { slug in
        hasPDF(slug: slug, sourceSlugs: sourceSlugs)
    } ?? false

    // 6. Title — note type prefers first_heading first.
    let titleValue: String?
    if entryType == "note" {
        titleValue = firstHeading(body)
            ?? truthyText(frontmatter, "title").map { stripWiki($0) }
            ?? truthyText(frontmatter, "name").map { stripWiki($0) }
    } else {
        titleValue = (truthyText(frontmatter, "title")
            ?? truthyText(frontmatter, "name"))
            .map { stripWiki($0) }
    }

    // 7. Year and rating.
    //    field_json = fieldJSONCell(field(...))
    let yearJSONValue: String? = fieldJSONCell(field(frontmatter, "year"))
    let ratingSource: YamlValue? = field(frontmatter, "rating")
    let ratingJSONValue: String? = ratingSource.flatMap { truthyJSONCell($0) }
    let ratingScoreValue: Double = ratingSource.map { ratingScore($0) } ?? 0.0

    // 8. Themes, author.
    let themesValue: [String]? = themeArray(field(frontmatter, "themes"))
    let authorValue: String? = (field(frontmatter, "author") ?? field(frontmatter, "authors"))
        .flatMap { flattenAuthor($0) }

    // 9. Titles (en, cn), publisher, isbn, translation fields.
    let titleEnValue: String? = titleEn(frontmatter)
    let titleCnValue: String? = titleCn(frontmatter, type: entryType,
                                        title: titleValue, body: body)
    let publisherValue: String? = truthyText(frontmatter, "publisher").map { stripWiki($0) }
    let isbnValue: String? = truthyText(frontmatter, "isbn")
    let translationTitleCnValue: String? = translationTitleCn(frontmatter)
    let translationDoubanURLValue: String? = translationDoubanUrl(frontmatter)

    // 10. Body helpers.
    let bodyTextValue: String = normalizeBodyForSearch(body)
    let bodyLenValue: Int64 = Int64(bodyTextValue.unicodeScalars.count)
    let previewValue: String = firstParagraph(body)

    // 11. Search text — 9 parts, same order as Rust.
    let searchTextValue: String = searchText([
        rel,
        titleValue ?? "",
        titleEnValue ?? "",
        titleCnValue ?? "",
        authorValue ?? "",
        publisherValue ?? "",
        isbnValue ?? "",
        translationTitleCnValue ?? "",
        bodyTextValue,
    ])

    // 12. Remaining optional fields.
    let topicValue: String? = truthyText(frontmatter, "topic")
    let sourceValue: String? = truthyText(frontmatter, "source")
    let doiValue: String? = truthyText(frontmatter, "doi")
    let chaptersAnalyzedValue: Int64? = intValue(field(frontmatter, "chapters_analyzed"))
    let annotatesValue: String? = truthyText(frontmatter, "annotates")
    let createdValue: String? = textValue(field(frontmatter, "created"))

    let entry = IndexedEntry(
        path: rel,
        entryType: entryType,
        book: book,
        title: titleValue,
        titleEn: titleEnValue,
        titleCn: titleCnValue,
        author: authorValue,
        yearJSON: yearJSONValue,
        ratingJSON: ratingJSONValue,
        ratingScore: ratingScoreValue,
        themes: themesValue,
        topic: topicValue,
        source: sourceValue,
        doi: doiValue,
        publisher: publisherValue,
        isbn: isbnValue,
        translationTitleCn: translationTitleCnValue,
        translationDoubanURL: translationDoubanURLValue,
        chaptersAnalyzed: chaptersAnalyzedValue,
        annotates: annotatesValue,
        created: createdValue,
        pdfSlug: pdfSlugValue,
        hasPDF: hasPDFValue,
        mtime: mtimeMs,
        preview: previewValue,
        bodyLen: bodyLenValue,
        added: 0,
        bodyText: bodyTextValue,
        searchText: searchTextValue
    )

    return .indexed(entry)
}
