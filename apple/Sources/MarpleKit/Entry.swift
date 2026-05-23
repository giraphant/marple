import Foundation

public enum EntryType: RawRepresentable, Codable, Sendable, Equatable {
    case paperAnalysis
    case bookOverview
    case chapterSummary
    case authorProfile
    case topicSynthesis
    case note
    /// Any entry type the reader doesn't model yet. The vault is produced by an
    /// evolving pipeline (e.g. "topic-reading-list"); preserving the raw value
    /// here means one unknown type never fails the whole index decode.
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "paper-analysis": self = .paperAnalysis
        case "book-overview": self = .bookOverview
        case "chapter-summary": self = .chapterSummary
        case "author-profile": self = .authorProfile
        case "topic-synthesis": self = .topicSynthesis
        case "note": self = .note
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .paperAnalysis: return "paper-analysis"
        case .bookOverview: return "book-overview"
        case .chapterSummary: return "chapter-summary"
        case .authorProfile: return "author-profile"
        case .topicSynthesis: return "topic-synthesis"
        case .note: return "note"
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

public struct Entry: Codable, Sendable, Identifiable, Equatable {
    public var id: String { path }
    public let path: String
    public let type: EntryType
    public let title: String?
    public let author: String?
    public let year: String?
    public let ratingScore: Double
    public let themes: [String]
    public let preview: String
    public let hasPDF: Bool

    enum CodingKeys: String, CodingKey {
        case path, type, title, author, year, preview
        case ratingScore = "rating_score"
        case themes
        case hasPDF = "has_pdf"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        type = try c.decode(EntryType.self, forKey: .type)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        preview = (try? c.decodeIfPresent(String.self, forKey: .preview)) ?? ""
        ratingScore = (try? c.decodeIfPresent(Double.self, forKey: .ratingScore)) ?? 0
        themes = (try? c.decodeIfPresent([String].self, forKey: .themes)) ?? []
        hasPDF = (try? c.decodeIfPresent(Bool.self, forKey: .hasPDF)) ?? false
        if let s = try? c.decodeIfPresent(String.self, forKey: .year) {
            year = s
        } else if let i = try? c.decodeIfPresent(Int.self, forKey: .year) {
            year = String(i)
        } else if let d = try? c.decodeIfPresent(Double.self, forKey: .year) {
            year = String(Int(d))
        } else {
            year = nil
        }
    }

    public init(path: String, type: EntryType, title: String?, author: String?,
                year: String?, ratingScore: Double, themes: [String],
                preview: String, hasPDF: Bool) {
        self.path = path
        self.type = type
        self.title = title
        self.author = author
        self.year = year
        self.ratingScore = ratingScore
        self.themes = themes
        self.preview = preview
        self.hasPDF = hasPDF
    }
}
