import SwiftUI
import MarpleKit

/// UserDefaults keys for user settings. Plain `@AppStorage` rather than a Codable
/// blob: the set is small and each control binds to one key directly.
enum SettingsKeys {
    static let theme = "marple.theme"
    static let readingFontFamily = "marple.readingFontFamily"
    static let readingFontSize = "marple.readingFontSize"
    static let readingLineHeight = "marple.readingLineHeight"
    static let externalEditor = "marple.externalEditor"
    static let citationFormat = "marple.citationFormat"
    static let citationClickAction = "marple.citationClickAction"
    static let originalClickAction = "marple.originalClickAction"
}

/// What a single click on the 引用 toolbar button does. Right-click always shows
/// the full format menu regardless of this.
enum CitationClickAction: String, CaseIterable {
    case copyDefault, showMenu
    var label: String {
        switch self {
        case .copyDefault: return "复制默认格式"
        case .showMenu:    return "打开格式菜单"
        }
    }
}

/// What a single click on the 原文 toolbar button does. Right-click always shows
/// the 原文 / 译本 menu regardless of this.
enum OriginalClickAction: String, CaseIterable {
    case openOriginal, showMenu
    var label: String {
        switch self {
        case .openOriginal: return "打开原始 PDF"
        case .showMenu:     return "打开菜单（原文 / 译本）"
        }
    }
}

/// Color-scheme preference. `.system` defers to the OS appearance.
enum ThemePreference: String, CaseIterable {
    case system, light, dark
    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light:  return "浅色"
        case .dark:   return "深色"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

/// Reading-column font face. System faces map to a `Font.Design`; the bundled
/// custom faces (see FontRegistration) carry a PostScript name resolved via
/// `Font.custom`. Native equivalent of the web 苹方/宋体/等宽 presets, plus the
/// trial Chinese reading fonts.
enum ReadingFontFamily: String, CaseIterable {
    case sans, serif, mono
    case fzPingXianYaSong, fzYouHei, lxgwNeoZhiSong, lxgwWenKai

    var label: String {
        switch self {
        case .sans:  return "苹方"
        case .serif: return "宋体"
        case .mono:  return "等宽"
        case .fzPingXianYaSong: return "方正屏显雅宋"
        case .fzYouHei:         return "方正悠黑"
        case .lxgwNeoZhiSong:   return "霞鹜新致宋"
        case .lxgwWenKai:       return "霞鹜文楷(屏阅)"
        }
    }

    /// System font design; `.default` for custom faces (they carry their own face).
    var design: Font.Design {
        switch self {
        case .serif: return .serif
        case .mono:  return .monospaced
        default:     return .default
        }
    }

    /// PostScript name of the bundled custom font, or nil for system faces.
    var customFontName: String? {
        switch self {
        case .fzPingXianYaSong: return "FZPingXYSJW--GB1-0"
        case .fzYouHei:         return "FZYHJW"
        case .lxgwNeoZhiSong:   return "LXGWNeoZhiSongPlus"
        case .lxgwWenKai:       return "LXGWWenKaiMonoScreen"
        default:                return nil
        }
    }
}

/// Discrete option sets for the reading-typography controls.
enum ReadingDefaults {
    static let fontSize: Double = 15
    static let lineHeight: Double = 1.62
    static let fontSizeOptions: [Double] = [15, 16, 17, 18, 19]
    static let lineHeightOptions: [Double] = [1.62, 1.78, 1.9]
}

/// Resolved reading-typography config, injected through the environment so the
/// markdown blocks can pick it up off the render path. `lineSpacing` converts the
/// unitless line-height multiplier (web model) into SwiftUI's extra-points model.
struct ReadingFontConfig: Equatable {
    var size: Double
    var design: Font.Design
    var lineHeight: Double
    var customName: String? = nil

    /// A font at an arbitrary size/weight honoring the chosen face — custom
    /// (bundled, by PostScript name) or system (by design). Used for both body
    /// and headings so the whole reader shares one face.
    func font(size: Double, weight: Font.Weight = .regular) -> Font {
        if let customName {
            return .custom(customName, size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: design)
    }

    var bodyFont: Font { font(size: size) }
    var lineSpacing: CGFloat { CGFloat(size * (lineHeight - 1)) }

    static let `default` = ReadingFontConfig(
        size: ReadingDefaults.fontSize, design: .default, lineHeight: ReadingDefaults.lineHeight)
}

private struct ReadingFontKey: EnvironmentKey {
    static let defaultValue = ReadingFontConfig.default
}

extension EnvironmentValues {
    var readingFont: ReadingFontConfig {
        get { self[ReadingFontKey.self] }
        set { self[ReadingFontKey.self] = newValue }
    }
}
