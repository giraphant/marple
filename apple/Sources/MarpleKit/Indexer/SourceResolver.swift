import Foundation

// MARK: - loadSourceSlugs
// Mirrors indexer.rs `load_source_slugs` (:588-608):
// scan `sourcesDir` for *.pdf (case-insensitive extension), return the bare file stems.

public func loadSourceSlugs(sourcesDir: String) -> Set<String> {
    var slugs = Set<String>()
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: sourcesDir) else {
        return slugs
    }
    for name in entries {
        let url = URL(fileURLWithPath: name)
        if url.pathExtension.lowercased() == "pdf" {
            slugs.insert(url.deletingPathExtension().lastPathComponent)
        }
    }
    return slugs
}

private struct SourceSlugCandidate: Sendable {
    let slug: String
    let titleTokens: Set<String>
    let year: Int?
}

/// Precomputed lookup for `hasPDF`.
///
/// Full index rebuilds call the resolver once per paper/book/chapter. Building
/// candidate title tokens once keeps fuzzy matching proportional to same-surname
/// candidates instead of `entries × all PDFs`.
public struct SourceSlugIndex: Sendable {
    private let slugs: Set<String>
    private let byFirstToken: [String: [SourceSlugCandidate]]

    public init(_ slugs: Set<String>) {
        self.slugs = slugs
        var buckets: [String: [SourceSlugCandidate]] = [:]
        for slug in slugs {
            guard let first = slugFirstTokenLower(slug) else { continue }
            buckets[first, default: []].append(SourceSlugCandidate(
                slug: slug,
                titleTokens: slugTitleTokens(slug),
                year: slugYear(slug)
            ))
        }
        self.byFirstToken = buckets
    }

    public func hasPDF(slug: String) -> Bool {
        guard !slug.isEmpty else { return false }
        if slugs.contains(slug) { return true }
        return fuzzyPickSource(slug) != nil
    }

    public func fuzzyPickSource(_ expected: String) -> String? {
        let expTokens = expected.split(separator: "-").filter { !$0.isEmpty }.map(String.init)
        if expTokens.isEmpty { return nil }
        let expLast = expTokens[0].lowercased()
        let expTitle = slugTitleTokens(expected)
        if expTitle.count < 2 { return nil }
        let expYear = slugYear(expected)

        var best: (score: Double, cand: String)?
        var runnerUp: (score: Double, cand: String)?
        var matched = 0
        for cand in byFirstToken[expLast] ?? [] {
            let inter = expTitle.intersection(cand.titleTokens).count
            if inter < 2 { continue }
            let union = expTitle.union(cand.titleTokens).count
            if union == 0 { continue }
            let jac = Double(inter) / Double(union)
            if jac < 0.6 { continue }

            let identical = expTitle == cand.titleTokens
            let yearClose: Bool
            if let a = expYear, let b = cand.year {
                yearClose = abs(a - b) <= 5
            } else {
                yearClose = false
            }
            guard identical || yearClose else { continue }

            matched += 1
            let candidate = (score: jac, cand: cand.slug)
            if best == nil || candidate.score > best!.score {
                runnerUp = best
                best = candidate
            } else if runnerUp == nil || candidate.score > runnerUp!.score {
                runnerUp = candidate
            }
        }

        guard let best else { return nil }
        if matched == 1 { return best.cand }
        if let runnerUp, best.score - runnerUp.score > 0.15 {
            return best.cand
        }
        return nil
    }
}

// MARK: - bookSlug
// Mirrors indexer.rs `book_slug` (:1138-1143):
// first path component after "vault/books/", or nil.

public func bookSlug(_ rel: String) -> String? {
    guard let rest = rel.hasPrefix("vault/books/") ? String(rel.dropFirst("vault/books/".count)) : nil else {
        return nil
    }
    let first = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
    guard let slug = first, !slug.isEmpty else { return nil }
    return slug
}

// MARK: - pdfSlug
// PDF source slug derivation (QUA-119 short forms):
// paper → fileStem; book → bookSlug(rel);
// chapter → bookSlug(rel)-fileStem (avoids cross-book chapter-name collisions).

public func pdfSlug(type: String, rel: String, fileStem: String) -> String? {
    switch type {
    case "paper":
        return fileStem
    case "book":
        return bookSlug(rel)
    case "chapter":
        return bookSlug(rel).map { "\($0)-\(fileStem)" }
    default:
        return nil
    }
}

// MARK: - hasPDF
// Mirrors indexer.rs has_pdf derivation (:168-173):
// exact slug in sourceSlugs OR fuzzyPickSource returns a hit.

public func hasPDF(slug: String, sourceSlugs: Set<String>) -> Bool {
    SourceSlugIndex(sourceSlugs).hasPDF(slug: slug)
}

// MARK: - fuzzy_pick_source helpers
// Mirrors lib.rs constants and helpers (:1057-1082).

private let slugStopwords: Set<String> = [
    "the", "of", "a", "an", "and", "to", "in", "on", "for", "from", "at", "by",
    "with", "de", "la", "le", "el", "und", "der", "die", "das",
]

/// Mirrors lib.rs `is_year_token` (:1062-1064):
/// exactly 4 ASCII digit characters.
private func isYearToken(_ t: String) -> Bool {
    t.count == 4 && t.unicodeScalars.allSatisfy { $0.value >= 0x30 && $0.value <= 0x39 }
}

/// Mirrors lib.rs `slug_year` (:1067-1072):
/// trailing 4-digit year of a slug scanning from the end.
private func slugYear(_ slug: String) -> Int? {
    let parts = slug.split(separator: "-").map(String.init)
    return parts.reversed().first(where: { isYearToken($0) }).flatMap { Int($0) }
}

/// Mirrors lib.rs `slug_title_tokens` (:1076-1082):
/// drop leading lastname (skip(1)), drop year tokens, drop stopwords; lowercase the rest.
private func slugTitleTokens(_ slug: String) -> Set<String> {
    var result = Set<String>()
    let parts = slug.split(separator: "-").map(String.init)
    guard parts.count > 1 else { return result }
    for token in parts.dropFirst() {
        let t = token  // already String
        if t.isEmpty { continue }
        if isYearToken(t) { continue }
        let lower = t.lowercased()
        if slugStopwords.contains(lower) { continue }
        result.insert(lower)
    }
    return result
}

/// Lowercased first slug token without allocating the full `slug.split("-")`
/// array. The fuzzy matcher calls this for every candidate, so keeping the
/// surname prefilter cheap matters on large source directories.
private func slugFirstTokenLower(_ slug: String) -> String? {
    guard !slug.isEmpty else { return nil }
    let end = slug.firstIndex(of: "-") ?? slug.endIndex
    return String(slug[..<end]).lowercased()
}

// MARK: - fuzzyPickSource
// Mirrors lib.rs `fuzzy_pick_source` (:1121-1172) verbatim.

/// Conservative fuzzy match of an expected slug to an actual source stem.
/// Rules (all must hold):
///   - same leading lastname token (case-insensitive)
///   - ≥2 shared significant title tokens
///   - Jaccard ≥ 0.6
///   - identical title token sets OR year within ±5
///   - single clear winner: only one candidate, OR top beats runner-up by > 0.15
public func fuzzyPickSource(_ expected: String, _ candidates: Set<String>) -> String? {
    SourceSlugIndex(candidates).fuzzyPickSource(expected)
}
