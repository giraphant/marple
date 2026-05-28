import Foundation

public enum EntryType: RawRepresentable, Codable, Sendable, Equatable, Hashable {
    case paper
    case book
    case chapter
    case author
    case topic
    case journal
    case note
    case image
    /// Any type the reader doesn't model. The vault is produced by an evolving
    /// pipeline and may carry experimental kinds (e.g. "topic-reading-list").
    /// Holding the raw value here means one unknown type doesn't fail the whole
    /// index decode — the entry surfaces as `.other` rather than being silently
    /// dropped or normalized to a familiar bucket.
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "paper":   self = .paper
        case "book":    self = .book
        case "chapter": self = .chapter
        case "author":  self = .author
        case "topic":   self = .topic
        case "journal": self = .journal
        case "note":    self = .note
        case "image":   self = .image
        default:        self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .paper:   return "paper"
        case .book:    return "book"
        case .chapter: return "chapter"
        case .author:  return "author"
        case .topic:   return "topic"
        case .journal: return "journal"
        case .note:    return "note"
        case .image:   return "image"
        case .other(let raw): return raw
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self.init(rawValue: raw)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

public extension EntryType {
    /// The eight modeled types in the canonical sidebar order (mirrors web TYPES).
    static let modeled: [EntryType] = [
        .paper, .book, .author,
        .topic, .journal, .chapter, .note, .image,
    ]

    var label: String {
        switch self {
        case .paper:   return "论文"
        case .book:    return "图书"
        case .author:  return "作者"
        case .topic:   return "主题"
        case .journal: return "期刊"
        case .chapter: return "章节"
        case .note:    return "笔记"
        case .image:   return "图片"
        case .other(let raw): return raw
        }
    }
}

public struct Entry: Codable, Sendable, Identifiable, Equatable {
    public var id: String { path }
    public let path: String
    public let type: EntryType
    public let title: String?
    /// Authors as a list. Empty means no author. Per QUA-109, the canonical
    /// shape is always a list (single-author = 1-element list) — no scalar
    /// branch on consumers. Legacy cache rows that stored a joined string
    /// are split via `splitAuthors` on decode.
    public let author: [String]
    public let year: String?
    public let ratingScore: Double
    public let themes: [String]
    public let preview: String
    public let hasPDF: Bool
    public let pdfSlug: String?
    public let mtime: Double?
    public let added: Double?
    public let source: String?
    public let book: String?
    public let topic: String?
    public let kind: String?
    public let journal: String?
    public let doi: String?
    public let publisher: String?
    public let isbn: String?
    public let category: String?
    public let annotates: String?
    public let created: String?

    enum CodingKeys: String, CodingKey {
        case path, type, title, author, year, preview
        case ratingScore = "rating_score"
        case themes
        case hasPDF = "has_pdf"
        case pdfSlug = "pdf_slug"
        case mtime, added, source, book, topic, kind, journal, doi, publisher, isbn, category, annotates, created
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        type = try c.decode(EntryType.self, forKey: .type)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        // Author: prefer new array shape; fall back to legacy joined-string for
        // caches written before QUA-109. Missing or unknown shape → empty.
        if let list = try? c.decode([String].self, forKey: .author) {
            author = list
        } else if let scalar = try? c.decode(String.self, forKey: .author) {
            author = splitAuthors(scalar)
        } else {
            author = []
        }
        preview = (try? c.decodeIfPresent(String.self, forKey: .preview)) ?? ""
        ratingScore = (try? c.decodeIfPresent(Double.self, forKey: .ratingScore)) ?? 0
        themes = (try? c.decodeIfPresent([String].self, forKey: .themes)) ?? []
        hasPDF = (try? c.decodeIfPresent(Bool.self, forKey: .hasPDF)) ?? false
        pdfSlug = try? c.decodeIfPresent(String.self, forKey: .pdfSlug)
        if let s = try? c.decodeIfPresent(String.self, forKey: .year) {
            year = s
        } else if let i = try? c.decodeIfPresent(Int.self, forKey: .year) {
            year = String(i)
        } else if let d = try? c.decodeIfPresent(Double.self, forKey: .year) {
            year = String(Int(d))
        } else {
            year = nil
        }
        mtime = (try? c.decodeIfPresent(Double.self, forKey: .mtime)) ?? nil
        added = (try? c.decodeIfPresent(Double.self, forKey: .added)) ?? nil
        source = (try? c.decodeIfPresent(String.self, forKey: .source)) ?? nil
        book = (try? c.decodeIfPresent(String.self, forKey: .book)) ?? nil
        topic = (try? c.decodeIfPresent(String.self, forKey: .topic)) ?? nil
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil
        journal = (try? c.decodeIfPresent(String.self, forKey: .journal)) ?? nil
        doi = (try? c.decodeIfPresent(String.self, forKey: .doi)) ?? nil
        publisher = (try? c.decodeIfPresent(String.self, forKey: .publisher)) ?? nil
        isbn = (try? c.decodeIfPresent(String.self, forKey: .isbn)) ?? nil
        category = (try? c.decodeIfPresent(String.self, forKey: .category)) ?? nil
        annotates = (try? c.decodeIfPresent(String.self, forKey: .annotates)) ?? nil
        created = (try? c.decodeIfPresent(String.self, forKey: .created)) ?? nil
    }

    public init(path: String, type: EntryType, title: String?, author: [String],
                year: String?, ratingScore: Double, themes: [String],
                preview: String, hasPDF: Bool, pdfSlug: String? = nil,
                mtime: Double? = nil, added: Double? = nil, source: String? = nil,
                book: String? = nil, topic: String? = nil, kind: String? = nil,
                journal: String? = nil, doi: String? = nil, publisher: String? = nil,
                isbn: String? = nil, category: String? = nil, annotates: String? = nil,
                created: String? = nil) {
        self.path = path
        self.type = type
        self.title = title
        self.author = author
        self.year = year
        self.ratingScore = ratingScore
        self.themes = themes
        self.preview = preview
        self.hasPDF = hasPDF
        self.pdfSlug = pdfSlug
        self.mtime = mtime
        self.added = added
        self.source = source
        self.book = book
        self.topic = topic
        self.kind = kind
        self.journal = journal
        self.doi = doi
        self.publisher = publisher
        self.isbn = isbn
        self.category = category
        self.annotates = annotates
        self.created = created
    }
}

public extension Entry {
    /// Copy with selected metadata fields replaced. Double-optional params let a
    /// caller clear a field (`.some(nil)`) vs leave it unchanged (omit).
    /// `author` uses single-optional because the value type itself
    /// (`[String]`) already encodes "empty" — pass `[]` to clear.
    func with(title: String?? = nil, author: [String]? = nil,
              ratingScore: Double? = nil, year: String?? = nil, source: String?? = nil,
              topic: String?? = nil, doi: String?? = nil, themes: [String]? = nil) -> Entry {
        Entry(path: path, type: type, title: title ?? self.title,
              author: author ?? self.author,
              year: year ?? self.year, ratingScore: ratingScore ?? self.ratingScore,
              themes: themes ?? self.themes, preview: preview, hasPDF: hasPDF,
              pdfSlug: pdfSlug, mtime: mtime, added: added, source: source ?? self.source,
              book: book, topic: topic ?? self.topic, kind: kind, journal: journal,
              doi: doi ?? self.doi, publisher: publisher, isbn: isbn, category: category,
              annotates: annotates, created: created)
    }
}
