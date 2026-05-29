// MARK: - IndexedEntry
//
// One struct per row in the `entries` SQLite table, plus the `BuildOutcome`
// enum and the `buildIndexedEntry` free function.
//
// Mirrors `IndexedEntry` struct (:80-116), `BuildOutcome` enum (:120-128), and
// `build_indexed_entry` function (:132-244) in
// `rust/reader-core/src/indexer.rs` — read those line ranges as the spec.

import Foundation

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

    /// Canonical short-form type string (output of `canonicalType`), e.g.
    /// `"paper"`. One of `paper / book / chapter / author / topic / journal /
    /// note / image`.  Column: `type`.
    public var entryType: String

    /// For `chapter` entries only: first path component after `"vault/books/"`.
    /// Column: `book`.
    public var book: String?

    // MARK: Titles

    /// Primary display title after `stripWiki`.  Column: `title`.
    public var title: String?

    /// English title from `title_en` / `chapter_title_en`.  Column: `title_en`.
    public var titleEn: String?

    /// Chinese title from frontmatter or (book only) first Chinese H1.
    /// Column: `title_cn`.
    public var titleCn: String?

    // MARK: Attribution

    /// Parsed author list (single-author = 1-element list, no scalar branch).
    /// Empty means no author. Column: `author` (TEXT — stored as
    /// `joined(", ")` for FTS / sort compatibility; readers split back via
    /// `splitAuthors` on row decode).
    public var author: [String]

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

    /// Topic-corpus membership slugs.  Column: `topics_json` (JSON array TEXT).
    /// Mirrors `themes`; optional in the Quasi schema (QUA-137).
    public var topics: [String]?

    // MARK: Bibliographic metadata

    /// Column: `kind`.
    public var kind: String?

    /// Column: `journal`.
    public var journal: String?

    /// Column: `source`.
    public var source: String?

    /// Column: `doi`.
    public var doi: String?

    /// Column: `publisher`.
    public var publisher: String?

    /// Column: `isbn`.
    public var isbn: String?

    /// Column: `category`.
    public var category: String? = nil

    // MARK: Translation / localisation

    /// Column: `translation_title_cn`.
    public var translationTitleCn: String?

    /// Column: `translation_douban_url`.
    public var translationDoubanURL: String?

    // MARK: Chapter / reference links

    /// Number of chapters analyzed (for book entries).  Column: `chapters_analyzed`.
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

    /// Has a `type` value that `canonicalType` does not recognize: empty / "A"
    /// sentinels OR a legacy/free-text type (e.g. `paper-analysis`, `monograph`,
    /// `reading-list`). The rejected raw value travels in the associated value
    /// so callers can report which vault file produced an unrecognized type
    /// instead of silently dropping it (QUA-119).
    case skippedUnknownType(String)

    /// No frontmatter fence at all — a plain markdown file.
    case skipped
}

// MARK: - Unknown-type diagnostic sink

/// One unknown-type report. `path` is the vault-relative path,
/// `rawType` is the rejected frontmatter `type:` value.
public struct UnknownTypeReport: Sendable, Equatable {
    public let path: String
    public let rawType: String
    public init(path: String, rawType: String) {
        self.path = path
        self.rawType = rawType
    }
}

/// Diagnostic sink for unknown frontmatter `type:` values surfaced by
/// `buildIndexedEntry`. The default handler writes one line per report to
/// stderr so a stale vault file is visibly skipped instead of silently
/// vanishing from the index — a first-boot migration with N stale files emits
/// N stderr lines, which is intentional: those lines are the unique signal
/// that the vault still needs cleanup.
///
/// Tests install an override via `$override.withValue(handler) { ... }`. The
/// override is `@TaskLocal`, so parallel test cases (Swift Testing runs each
/// `@Test` in its own Task) each see their own handler and don't race over a
/// shared mutable global.
///
/// The handler runs synchronously inside `buildIndexedEntry`, so keep it cheap.
public enum UnknownTypeReporter {

    /// Per-task override. `nil` (the default) falls through to `defaultHandler`.
    /// Tests wrap the relevant `buildIndexedEntry` call in
    /// `UnknownTypeReporter.$override.withValue(capture) { ... }`.
    @TaskLocal
    public static var override: (@Sendable (UnknownTypeReport) -> Void)?

    /// Production default: one stderr line per report.
    public static let defaultHandler: @Sendable (UnknownTypeReport) -> Void = { report in
        FileHandle.standardError.write(Data(
            "[marple] skipping vault entry with unrecognized type=\(report.rawType): \(report.path)\n".utf8
        ))
    }

    /// Submit one report. Routes to the task-local override when present.
    public static func report(_ report: UnknownTypeReport) {
        if let override {
            override(report)
        } else {
            defaultHandler(report)
        }
    }
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

    // 4. Canonical type mapping (QUA-119: only the eight short Quasi forms;
    //    everything else is reported and skipped, not silently normalized).
    guard let entryType = canonicalType(rawType) else {
        UnknownTypeReporter.report(
            UnknownTypeReport(path: rel, rawType: rawType)
        )
        return .skippedUnknownType(rawType)
    }

    // 5. Derive structural fields.

    // book: only for chapter entries
    let book: String? = entryType == "chapter" ? bookSlug(rel) : nil

    // pdf_slug
    let pdfSlugValue: String? = pdfSlug(type: entryType, rel: rel, fileStem: fileStem)

    // has_pdf
    let hasPDFValue: Bool = pdfSlugValue.map { slug in
        hasPDF(slug: slug, sourceSlugs: sourceSlugs)
    } ?? false

    // 6. Title.
    let titleValue: String? = resolveTitle(frontmatter, type: entryType, body: body)

    // 7. Year and rating.
    //    field_json = fieldJSONCell(field(...))
    let yearJSONValue: String? = fieldJSONCell(field(frontmatter, "year"))
    let ratingSource: YamlValue? = field(frontmatter, "rating")
    let ratingJSONValue: String? = ratingSource.flatMap { truthyJSONCell($0) }
    let ratingScoreValue: Double = ratingSource.map { ratingScore($0) } ?? 0.0

    // 8. Themes, topics, author.
    let themesValue: [String]? = themeArray(field(frontmatter, "themes"))
    let topicsValue: [String]? = themeArray(field(frontmatter, "topics"))
    let authorValue: [String] = parseAuthors(
        field(frontmatter, "author") ?? field(frontmatter, "authors")
    )

    // 9. Titles (en, cn), publisher, isbn, translation fields.
    let titleEnValue: String? = titleEn(frontmatter)
    let titleCnValue: String? = titleCn(frontmatter, type: entryType,
                                        title: titleValue, body: body)
    let publisherValue: String? = truthyText(frontmatter, "publisher").map { stripWiki($0) }
    let isbnValue: String? = truthyText(frontmatter, "isbn")
    let categoryValue: String? = truthyText(frontmatter, "category")
    let translationTitleCnValue: String? = translationTitleCn(frontmatter)
    let translationDoubanURLValue: String? = translationDoubanUrl(frontmatter)

    // 10. Body helpers.
    let bodyTextValue: String = normalizeBodyForSearch(body)
    let bodyLenValue: Int64 = Int64(bodyTextValue.unicodeScalars.count)
    let previewValue: String = firstParagraph(body)

    // 11. Search text — composite path/title/metadata/body text for trigram FTS.
    let searchTextValue: String = searchText([
        rel,
        titleValue ?? "",
        titleEnValue ?? "",
        titleCnValue ?? "",
        authorValue.joined(separator: ", "),
        topicsValue?.joined(separator: " ") ?? "",
        publisherValue ?? "",
        isbnValue ?? "",
        translationTitleCnValue ?? "",
        bodyTextValue,
    ])

    // 12. Remaining optional fields.
    let kindValue: String? = truthyText(frontmatter, "kind")
    let journalValue: String? = truthyText(frontmatter, "journal")
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
        topics: topicsValue,
        kind: kindValue,
        journal: journalValue,
        source: sourceValue,
        doi: doiValue,
        publisher: publisherValue,
        isbn: isbnValue,
        category: categoryValue,
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
