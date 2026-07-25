import SwiftUI
import AppKit
import MarpleKit

/// UserDefaults keys for user settings. Plain `@AppStorage` rather than a Codable
/// blob: the set is small and each control binds to one key directly.
enum SettingsKeys {
    static let theme = "marple.theme"
    static let readingFontFamily = "marple.readingFontFamily"
    static let readingFontSize = "marple.readingFontSize"
    static let readingLineHeight = "marple.readingLineHeight"
    static let readingLetterSpacing = "marple.readingLetterSpacing"
    static let externalEditor = "marple.externalEditor"
    static let citationFormat = "marple.citationFormat"
    static let citationClickAction = "marple.citationClickAction"
    static let originalClickAction = "marple.originalClickAction"
    // AI dispatch: which client preset is selected and the (editable) command
    // template it pre-filled. Defaults keep old installs on the Superset flow.
    static let aiDispatchTarget = "marple.aiDispatchTarget"
    static let aiDispatchTemplate = "marple.aiDispatchTemplate"
    static let supersetWorkspaceID = "marple.supersetWorkspaceID"
    static let supersetAgent = "marple.supersetAgent"
    static let supersetCLIPath = "marple.supersetCLIPath"
    static let supersetReanalyzePrompt = "marple.supersetReanalyzePrompt"
    static let supersetFormatPrompt = "marple.supersetFormatPrompt"
    static let supersetTranslatePrompt = "marple.supersetTranslatePrompt"
    static let supersetDiscussPrompt = "marple.supersetDiscussPrompt"
    // QUA-107: opt-in switch for the local CLI socket server (off by default).
    static let cliServerEnabled = "marple.cliServerEnabled"
    // QUA-106: local APFS-snapshot backups. Enabled by default (cheap + a safety
    // feature). `backupLocation` empty ⇒ ~/Library/Application Support/Marple/Backups/.
    static let backupEnabled = "marple.backupEnabled"
    static let backupLocation = "marple.backupLocation"
    // QUA-OOM diagnostics: opt-in; the watchdog wakes periodically by design.
    static let memoryWatchdogEnabled = "marple.memoryWatchdogEnabled"
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

/// Reading-column font face. Each case maps to a system-installed font family the
/// renderer resolves per-weight via `NSFontManager` (real weight cuts, not faux-bold).
/// `.sans` uses the system font directly (its CJK face is 苹方).
enum ReadingFontFamily: String, CaseIterable {
    case sans, yingHei, jingXiHei, jingXiRunHei, wenkai, pingXianYaSong, sourceHanSerif, youSong, neoZhiSong

    var label: String {
        switch self {
        case .sans:           return "苹方"
        case .yingHei:        return "蒙纳盈黑"
        case .jingXiHei:      return "文鼎晶熙黑"
        case .jingXiRunHei:   return "文鼎晶熙润黑"
        case .wenkai:         return "霞鹜文楷"
        case .pingXianYaSong: return "方正屏显雅宋"
        case .sourceHanSerif: return "思源宋体"
        case .youSong:        return "方正悠宋"
        case .neoZhiSong:     return "霞鹜新致宋"
        }
    }

    /// System font family name, or nil for the default system face (苹方 for CJK).
    var systemFamily: String? {
        switch self {
        case .sans:           return nil
        case .yingHei:        return "M Ying Hei PRC"
        case .jingXiHei:      return "AR UDJingXiHeiG30"
        case .jingXiRunHei:   return "AR JingXiRunHeiGB"
        case .wenkai:         return "LXGW WenKai"
        case .pingXianYaSong: return "FZPingXianYaSongS-R-GB"
        case .sourceHanSerif: return "Source Han Serif SC"
        case .youSong:        return "FZYouSongJ GBK"
        case .neoZhiSong:     return "LXGW Neo ZhiSong Plus"
        }
    }

    /// Body weight, tuned per-font to its own weight table. High-contrast 宋体 render
    /// faint on screen, so they get bumped up; how far depends on the family's cuts
    /// (悠宋's weight-5 member is a Light cut, so it needs semibold to read solid).
    /// 屏显雅宋 is screen-tuned at regular and stays as a thin-body control. 盈黑 sits at
    /// its W4 (regular) cut — W5 read a touch heavy. 晶熙黑/润黑 (full G30 families) floor
    /// at Medium(w6), so medium lands on that real cut — a solid body, real Bold above it.
    var bodyWeight: NSFont.Weight {
        switch self {
        case .youSong:                                 return .semibold
        case .sourceHanSerif, .neoZhiSong, .jingXiHei, .jingXiRunHei: return .medium
        case .sans, .yingHei, .wenkai, .pingXianYaSong: return .regular
        }
    }
}

/// Discrete option sets for the reading-typography controls.
enum ReadingDefaults {
    static let fontSize: Double = 15
    static let lineHeight: Double = 1.62
    static let fontSizeOptions: [Double] = [15, 16, 17, 18, 19]
    static let lineHeightOptions: [Double] = [1.62, 1.78, 1.9]

    /// CJK-only letter-spacing, as a fraction of the em (applied as `size * value`).
    /// Latin text is never tracked; this only loosens 中文.
    static let letterSpacing: Double = 0.04
    static let letterSpacingOptions: [Double] = [0.0, 0.02, 0.04, 0.06, 0.08]
    static func letterSpacingLabel(_ value: Double) -> String {
        switch value {
        case ..<0.01:  return "紧凑"
        case ..<0.03:  return "偏紧"
        case ..<0.05:  return "标准"
        case ..<0.07:  return "舒朗"
        default:       return "宽松"
        }
    }
}

/// Resolved reading-typography config, injected through the environment so the
/// markdown blocks can pick it up off the render path. `lineSpacing` converts the
/// unitless line-height multiplier (web model) into SwiftUI's extra-points model.
struct ReadingFontConfig: Equatable {
    var size: Double
    /// System font family for the reader, or nil for the default system face.
    var fontFamily: String?
    var bodyWeight: NSFont.Weight = .regular
    var lineHeight: Double
    /// CJK letter-spacing as a fraction of the em (see `ReadingDefaults.letterSpacing`).
    var letterSpacing: Double = ReadingDefaults.letterSpacing

    static let `default` = ReadingFontConfig(
        size: ReadingDefaults.fontSize, fontFamily: nil, lineHeight: ReadingDefaults.lineHeight)
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
