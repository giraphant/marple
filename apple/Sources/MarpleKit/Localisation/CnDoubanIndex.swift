import Foundation

/// Read-only view of the vault's Chinese-translation index, written by the Quasi
/// plugin's `quasi-helpers localise` to `<workspaceRoot>/.quasi/localise/cndouban.json`.
///
/// The canonical book schema keeps the 中译本 index *out* of frontmatter (see the
/// Quasi `book.py` note: "中译本索引不在 frontmatter,完全外挂在 cndouban.json"). Marple is
/// a pure consumer: it never writes this file. It is loaded at runtime (not baked
/// into the SQLite index) because `quasi-helpers localise` maintains it
/// independently of the `.md` files — an index-time join would go stale until the
/// next full rebuild. When the file is absent/unreadable/malformed, `load` returns
/// nil and the 译本 row simply doesn't appear (graceful degradation).
///
/// The file has two blocks:
///   - `by_isbn`: per-ISBN localisation status (`found` / `none` / `error`), the
///     user's `selected_id` (if curated), a `cndouban_ids` list, and inline
///     `books[]` candidates.
///   - `by_douban_id`: rich per-edition records (title, author, translator, …).
///
/// We resolve each `found` ISBN to a single edition at load time, preferring the
/// curated `selected_id`, then the first `cndouban_ids` entry, then an inline
/// `books[]` candidate — looking the title/URL up in `by_douban_id` when needed.
public struct CnDoubanIndex: Sendable {

    /// One resolved Chinese edition for a book.
    public struct Translation: Sendable, Equatable {
        /// Chinese (usually Simplified) title of the translated edition.
        public let titleCn: String
        /// Full Douban subject URL, or nil when no valid URL can be formed
        /// (e.g. a hand-entered non-numeric placeholder id).
        public let doubanURL: String?

        public init(titleCn: String, doubanURL: String?) {
            self.titleCn = titleCn
            self.doubanURL = doubanURL
        }
    }

    /// Normalised-ISBN → resolved translation. Only `found` ISBNs that resolve to
    /// a non-empty title are present.
    private let byISBN: [String: Translation]

    public init(byISBN: [String: Translation]) {
        self.byISBN = byISBN
    }

    /// Resolve the Chinese edition for a book's ISBN, or nil when there is no
    /// translation (or the ISBN isn't indexed). ISBNs are compared on digits only
    /// so dashed (`978-0-…`) and plain forms match.
    public func translation(forISBN isbn: String?) -> Translation? {
        guard let key = Self.normalise(isbn) else { return nil }
        return byISBN[key]
    }
}

// MARK: - Loading

public extension CnDoubanIndex {
    static let relativePath = ".quasi/localise/cndouban.json"

    /// Load and resolve the localisation sidecar under
    /// `<workspaceRoot>/.quasi/localise/cndouban.json`. Returns nil when the file
    /// is absent, unreadable, or malformed.
    static func load(workspaceRoot: String) -> CnDoubanIndex? {
        guard !workspaceRoot.isEmpty else { return nil }
        let url = URL(fileURLWithPath: workspaceRoot).appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(RawFile.self, from: data)
        else { return nil }

        let byDouban = file.by_douban_id ?? [:]
        var map: [String: Translation] = [:]
        map.reserveCapacity(file.by_isbn.count)
        for (isbn, entry) in file.by_isbn {
            guard let key = normalise(isbn),
                  let t = resolve(entry, byDouban: byDouban) else { continue }
            map[key] = t
        }
        return CnDoubanIndex(byISBN: map)
    }

    /// Strip everything but ISBN digits (and a trailing check `X`), uppercased,
    /// so `"978-0-262-13472-9"` and `"9780262134729"` compare equal. Returns nil
    /// for empty input.
    static func normalise(_ isbn: String?) -> String? {
        guard let isbn else { return nil }
        let cleaned = isbn.unicodeScalars.filter { s in
            (s.value >= 0x30 && s.value <= 0x39) || s == "X" || s == "x"
        }
        let key = String(String.UnicodeScalarView(cleaned)).uppercased()
        return key.isEmpty ? nil : key
    }

    /// Pick a single edition for one `by_isbn` record: only `found` resolves, and
    /// candidate ids are tried in curated-first order (`selected_id`, then
    /// `cndouban_ids`, then inline `books[]`).
    private static func resolve(_ entry: RawIsbnEntry, byDouban: [String: RawDoubanEntry]) -> Translation? {
        guard entry.status == "found" else { return nil }

        var ids: [String] = []
        func push(_ id: String?) {
            guard let id, !id.isEmpty, !ids.contains(id) else { return }
            ids.append(id)
        }
        push(entry.selected_id)
        (entry.cndouban_ids ?? []).forEach(push)
        (entry.books ?? []).forEach { push($0.douban_id) }

        for id in ids {
            let book = entry.books?.first { $0.douban_id == id }
            guard let title = nonEmpty(byDouban[id]?.title) ?? nonEmpty(book?.title) else { continue }
            return Translation(titleCn: title, doubanURL: doubanURL(id: id, book: book, douban: byDouban[id]))
        }
        return nil
    }

    /// Prefer an explicit `douban_url`; otherwise synthesise the canonical subject
    /// URL only for a numeric id (hand-entered `manual-…` ids have no real page).
    private static func doubanURL(id: String, book: RawBookCandidate?, douban: RawDoubanEntry?) -> String? {
        if let u = nonEmpty(book?.douban_url), u.hasPrefix("http") { return u }
        if let u = nonEmpty(douban?.douban_url), u.hasPrefix("http") { return u }
        if !id.isEmpty, id.allSatisfy(\.isNumber) {
            return "https://book.douban.com/subject/\(id)/"
        }
        return nil
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

// MARK: - Raw JSON shapes (lenient: one bad field never drops a whole record)

private struct RawFile: Decodable {
    let by_isbn: [String: RawIsbnEntry]
    let by_douban_id: [String: RawDoubanEntry]?
}

private struct RawIsbnEntry: Decodable {
    let status: String?
    let selected_id: String?
    let cndouban_ids: [String]?
    let books: [RawBookCandidate]?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        selected_id = try? c.decodeIfPresent(String.self, forKey: .selected_id)
        cndouban_ids = try? c.decodeIfPresent([String].self, forKey: .cndouban_ids)
        books = try? c.decodeIfPresent([RawBookCandidate].self, forKey: .books)
    }
    private enum CodingKeys: String, CodingKey { case status, selected_id, cndouban_ids, books }
}

private struct RawBookCandidate: Decodable {
    let douban_id: String?
    let douban_url: String?
    let title: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        douban_id = try? c.decodeIfPresent(String.self, forKey: .douban_id)
        douban_url = try? c.decodeIfPresent(String.self, forKey: .douban_url)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
    }
    private enum CodingKeys: String, CodingKey { case douban_id, douban_url, title }
}

private struct RawDoubanEntry: Decodable {
    let title: String?
    let douban_url: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        douban_url = try? c.decodeIfPresent(String.self, forKey: .douban_url)
    }
    private enum CodingKeys: String, CodingKey { case title, douban_url }
}
