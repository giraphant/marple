// MARK: - IndexTitles
//
// Free functions mirroring the title, localisation, and Douban URL helpers in
// `rust/reader-core/src/indexer.rs`.  Every function is a direct port;
// comments cite the corresponding Rust line ranges.

// MARK: - isCJK  (:877-884)

/// Return true if the given Unicode scalar falls within the three CJK ranges
/// that the Rust indexer checks:
///
///   - U+3400–U+4DBF  CJK Unified Ideographs Extension A
///   - U+4E00–U+9FFF  CJK Unified Ideographs
///   - U+F900–U+FAFF  CJK Compatibility Ideographs
///
/// Hiragana, Katakana, and other East-Asian ranges are intentionally excluded.
///
/// Mirrors `contains_cjk` (:877-884) — the Rust function checks the same
/// three ranges char-by-char; here we expose it on a single scalar.
public func isCJK(_ scalar: Unicode.Scalar) -> Bool {
    let v = scalar.value
    return (0x3400...0x4DBF).contains(v)
        || (0x4E00...0x9FFF).contains(v)
        || (0xF900...0xFAFF).contains(v)
}

// MARK: - firstChineseH1  (:859-875)

/// Find the first H1 heading line that contains at least one CJK character.
///
/// Rules (mirroring Rust `first_chinese_h1` :859-875):
/// - Trim each line.
/// - Count leading `#` characters; skip if the count is not exactly 1.
/// - The rest must start with whitespace (i.e. `# Heading`, not `#Nospace`).
/// - Trim the rest; skip if empty.
/// - Skip if no CJK scalar is present.
/// - Return the first match.
public func firstChineseH1(_ body: String) -> String? {
    for line in body.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Count leading '#' characters
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        guard hashes == 1 else { continue }
        let afterHashes = trimmed.dropFirst(hashes)
        // Must be followed by whitespace
        guard let firstAfter = afterHashes.first, firstAfter.isWhitespace else { continue }
        let heading = afterHashes.trimmingCharacters(in: .whitespaces)
        guard !heading.isEmpty else { continue }
        // Must contain at least one CJK scalar
        guard heading.unicodeScalars.contains(where: { isCJK($0) }) else { continue }
        return heading
    }
    return nil
}

// MARK: - titleEn  (:991-995)

/// Return the English title, checking `title_en` then `chapter_title_en`.
/// Strips wiki-link syntax and converts empty results to nil.
///
/// Mirrors `title_en_value` (:991-995).
public func titleEn(_ map: [(String, YamlValue)]) -> String? {
    (truthyText(map, "title_en")
        ?? truthyText(map, "chapter_title_en"))
        .map { stripWiki($0) }
}

// MARK: - titleCn  (:997-1015)

/// Return the Chinese title.
///
/// Checks `title_cn`, `title_zh`, `chapter_title_cn`, `chapter_title_zh` in
/// order, stripping wiki links.  For type `"book"` only, if no frontmatter key
/// was found, falls back to `firstChineseH1(body)` — but only if that heading
/// differs from `title` (prevents trivial self-references).
///
/// Mirrors `title_cn_value` (:997-1015).
public func titleCn(
    _ map: [(String, YamlValue)],
    type entryType: String,
    title: String?,
    body: String
) -> String? {
    let fromFrontmatter = (truthyText(map, "title_cn")
        ?? truthyText(map, "title_zh")
        ?? truthyText(map, "chapter_title_cn")
        ?? truthyText(map, "chapter_title_zh"))
        .map { stripWiki($0) }

    if let v = fromFrontmatter { return v }

    if entryType == "book" {
        return firstChineseH1(body).flatMap { heading in
            // filter(|heading| title != Some(heading.as_str()))
            if title == heading { return nil }
            return heading
        }
    }

    return nil
}

// MARK: - translationTitleCn  (:1017-1021)

/// Return the Chinese translation title from `localisations.zh.title`.
/// Strips wiki-link syntax.
///
/// Mirrors `translation_title_cn_value` (:1017-1021).
public func translationTitleCn(_ map: [(String, YamlValue)]) -> String? {
    localisationZh(map)
        .flatMap { zhMap in truthyText(zhMap, "title") }
        .map { stripWiki($0) }
}

// MARK: - translationDoubanUrl  (:1023-1028)

/// Return a normalised Douban URL from, in order:
///   1. `localisations.zh.douban_url`
///   2. top-level `douban_url`
///   3. top-level `cndouban`
///
/// Mirrors `translation_douban_url_value` (:1023-1028).
public func translationDoubanUrl(_ map: [(String, YamlValue)]) -> String? {
    // 1. localisations.zh.douban_url
    if let zhMap = localisationZh(map),
       let v = field(zhMap, "douban_url"),
       let url = doubanUrlFromValue(v) {
        return url
    }
    // 2. top-level douban_url
    if let v = field(map, "douban_url"),
       let url = doubanUrlFromValue(v) {
        return url
    }
    // 3. top-level cndouban
    if let v = field(map, "cndouban"),
       let url = doubanUrlFromValue(v) {
        return url
    }
    return nil
}

// MARK: - normaliseDoubanUrl  (:1049-1063)

/// Normalise a raw Douban URL or ID string.
///
/// - HTTP(S) URL → return as-is (trimmed).
/// - Digits-only (after trimming; non-digits stripped from a mixed string) →
///   `https://book.douban.com/subject/{id}/`.
/// - Empty / no-digit non-URL → nil.
///
/// Mirrors `normalise_douban_url` (:1049-1063).
/// Note: the Rust implementation strips ALL non-digit characters to form the id,
/// so "12abc" → id "12" → a valid URL.  We mirror that exactly.
public func normaliseDoubanUrl(_ s: String) -> String? {
    let trimmed = s.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
        return trimmed
    }
    // Keep only ASCII digits (Rust: `chars().filter(|c| c.is_ascii_digit())`)
    let id = trimmed.unicodeScalars
        .filter { $0.value >= 0x30 && $0.value <= 0x39 }
        .map { Character($0) }
        .map { String($0) }
        .joined()
    guard !id.isEmpty else { return nil }
    return "https://book.douban.com/subject/\(id)/"
}

// MARK: - Private helpers

// MARK: localisationZh  (:1030-1040)

/// Extract the `localisations.zh` sub-mapping.
///
/// `localisations` must be a mapping; `zh` may be:
/// - A mapping → returned directly.
/// - A sequence-of-mappings → first mapping element is returned.
/// - Anything else → nil.
///
/// Mirrors `localisation_zh` (:1030-1040).
private func localisationZh(_ map: [(String, YamlValue)]) -> [(String, YamlValue)]? {
    guard case .mapping(let locMap) = field(map, "localisations") else { return nil }
    switch field(locMap, "zh") {
    case .mapping(let m):
        return m
    case .sequence(let items):
        return items.lazy.compactMap {
            if case .mapping(let m) = $0 { return m }
            return nil
        }.first
    default:
        return nil
    }
}

// MARK: doubanUrlFromValue  (:1042-1047)

/// Extract and normalise a Douban URL from a YamlValue.
///
/// If the value is a sequence, tries each item recursively and returns the
/// first match.  Otherwise converts to text and normalises.
///
/// Mirrors `douban_url_from_value` (:1042-1047).
private func doubanUrlFromValue(_ v: YamlValue) -> String? {
    if case .sequence(let items) = v {
        return items.lazy.compactMap { doubanUrlFromValue($0) }.first
    }
    return textValue(v).flatMap { normaliseDoubanUrl($0) }
}
