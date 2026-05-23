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

/// Reading-column font face. Maps to a `Font.Design` (native equivalent of the
/// web 苹方/宋体/等宽 presets).
enum ReadingFontFamily: String, CaseIterable {
    case sans, serif, mono
    var label: String {
        switch self {
        case .sans:  return "苹方"
        case .serif: return "宋体"
        case .mono:  return "等宽"
        }
    }
    var design: Font.Design {
        switch self {
        case .sans:  return .default
        case .serif: return .serif
        case .mono:  return .monospaced
        }
    }
}

/// Discrete option sets for the reading-typography controls.
enum ReadingDefaults {
    static let fontSize: Double = 17
    static let lineHeight: Double = 1.6
    static let fontSizeOptions: [Double] = [15, 16, 17, 18, 19]
    static let lineHeightOptions: [Double] = [1.6, 1.78, 1.9]
}

/// Resolved reading-typography config, injected through the environment so the
/// markdown blocks can pick it up off the render path. `lineSpacing` converts the
/// unitless line-height multiplier (web model) into SwiftUI's extra-points model.
struct ReadingFontConfig: Equatable {
    var size: Double
    var design: Font.Design
    var lineHeight: Double

    var bodyFont: Font { .system(size: size, design: design) }
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
