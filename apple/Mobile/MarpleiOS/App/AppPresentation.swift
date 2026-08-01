import Foundation
import MarpleKit

/// Localized presentation vocabulary for the iOS shell. MarpleKit retains its
/// stable labels for shared and non-UI consumers.
enum AppPresentation {
    static func entryTypeLabel(_ type: EntryType) -> String {
        switch type {
        case .paper: return String(localized: "论文")
        case .book: return String(localized: "图书")
        case .author: return String(localized: "作者")
        case .topic: return String(localized: "专题")
        case .journal: return String(localized: "期刊")
        case .chapter: return String(localized: "章节")
        case .note: return String(localized: "笔记")
        case .image: return String(localized: "图片")
        case .talk: return String(localized: "讲座")
        case .transcript: return String(localized: "转写")
        case .other(let raw): return raw
        }
    }
}
