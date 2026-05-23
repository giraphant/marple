import Foundation

public enum EntryType: String, Codable, Sendable {
    case paperAnalysis = "paper-analysis"
    case bookOverview = "book-overview"
    case chapterSummary = "chapter-summary"
    case authorProfile = "author-profile"
    case topicSynthesis = "topic-synthesis"
    case note = "note"
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
