import Foundation
import MarpleKit

/// Bridges the 11 strictly whitelisted portable `@AppStorage` / `UserDefaults`
/// keys to `SyncedSettings`.
///
/// Loop prevention relies on comparing the full typed snapshot against `lastKnown`
/// rather than a scoped boolean flag, because `UserDefaults.didChangeNotification`
/// can arrive asynchronously after `applyRemote` returns.
@MainActor
final class SettingsSyncBridge {
    private let defaults: UserDefaults
    nonisolated(unsafe) private var observer: NSObjectProtocol?
    private(set) var lastKnown: SyncedSettings
    var onLocalChange: ((SyncedSettings) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.lastKnown = Self.read(from: defaults)
    }

    func startObserving() {
        guard observer == nil else { return }
        lastKnown = Self.read(from: defaults)
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleDefaultsDidChange()
            }
        }
    }

    func stopObserving() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Read the 11 whitelisted portable settings from `defaults`, applying the
    /// exact same defaults and clamping as `SettingsView`.
    static func read(from defaults: UserDefaults) -> SyncedSettings {
        let balanced = defaults.bool(forKey: SettingsKeys.balancedTermExpansion)
        let deep = defaults.bool(forKey: SettingsKeys.deepTermExpansion)
        let rawDepth = defaults.object(forKey: SettingsKeys.termExpansionDepth) as? Int ?? 2
        let theme = (defaults.string(forKey: SettingsKeys.theme)
            .flatMap(ThemePreference.init(rawValue:)) ?? .system).rawValue
        let fontFamily = (defaults.string(forKey: SettingsKeys.readingFontFamily)
            .flatMap(ReadingFontFamily.init(rawValue:)) ?? .sans).rawValue
        let fontSize = Self.sanitizedOption(
            defaults.object(forKey: SettingsKeys.readingFontSize) as? Double,
            allowed: ReadingDefaults.fontSizeOptions,
            fallback: ReadingDefaults.fontSize
        )
        let lineHeight = Self.sanitizedOption(
            defaults.object(forKey: SettingsKeys.readingLineHeight) as? Double,
            allowed: ReadingDefaults.lineHeightOptions,
            fallback: ReadingDefaults.lineHeight
        )
        let letterSpacing = Self.sanitizedOption(
            defaults.object(forKey: SettingsKeys.readingLetterSpacing) as? Double,
            allowed: ReadingDefaults.letterSpacingOptions,
            fallback: ReadingDefaults.letterSpacing
        )
        let citationFormat = (defaults.string(forKey: SettingsKeys.citationFormat)
            .flatMap(CitationFormat.init(rawValue:)) ?? .inlineEN).rawValue
        let citationClick = (defaults.string(forKey: SettingsKeys.citationClickAction)
            .flatMap(CitationClickAction.init(rawValue:)) ?? .copyDefault).rawValue
        let originalClick = (defaults.string(forKey: SettingsKeys.originalClickAction)
            .flatMap(OriginalClickAction.init(rawValue:)) ?? .openOriginal).rawValue

        return SyncedSettings(
            balancedTermExpansion: balanced,
            deepTermExpansion: deep,
            termExpansionDepth: rawDepth,
            theme: theme,
            readingFontFamily: fontFamily,
            readingFontSize: fontSize,
            readingLineHeight: lineHeight,
            readingLetterSpacing: letterSpacing,
            citationFormat: citationFormat,
            citationClickAction: citationClick,
            originalClickAction: originalClick
        )
    }

    /// Apply a remote `SyncedSettings` into `UserDefaults`, writing only valid
    /// fields that actually changed. Updates `lastKnown` BEFORE writing so any
    /// resulting `didChangeNotification` is recognized as a no-op echo.
    @discardableResult
    func applyRemote(_ remote: SyncedSettings) -> Bool {
        let current = Self.read(from: defaults)
        var target = current

        target.balancedTermExpansion = remote.balancedTermExpansion
        target.deepTermExpansion = remote.deepTermExpansion
        target.termExpansionDepth = min(max(remote.termExpansionDepth, 1), 5)

        if ThemePreference(rawValue: remote.theme) != nil {
            target.theme = remote.theme
        }
        if ReadingFontFamily(rawValue: remote.readingFontFamily) != nil {
            target.readingFontFamily = remote.readingFontFamily
        }
        if let size = Self.matchingOption(remote.readingFontSize, allowed: ReadingDefaults.fontSizeOptions) {
            target.readingFontSize = size
        }
        if let lh = Self.matchingOption(remote.readingLineHeight, allowed: ReadingDefaults.lineHeightOptions) {
            target.readingLineHeight = lh
        }
        if let ls = Self.matchingOption(remote.readingLetterSpacing, allowed: ReadingDefaults.letterSpacingOptions) {
            target.readingLetterSpacing = ls
        }
        if CitationFormat(rawValue: remote.citationFormat) != nil {
            target.citationFormat = remote.citationFormat
        }
        if CitationClickAction(rawValue: remote.citationClickAction) != nil {
            target.citationClickAction = remote.citationClickAction
        }
        if OriginalClickAction(rawValue: remote.originalClickAction) != nil {
            target.originalClickAction = remote.originalClickAction
        }

        lastKnown = target
        guard target != current else { return false }

        if target.balancedTermExpansion != current.balancedTermExpansion {
            defaults.set(target.balancedTermExpansion, forKey: SettingsKeys.balancedTermExpansion)
        }
        if target.deepTermExpansion != current.deepTermExpansion {
            defaults.set(target.deepTermExpansion, forKey: SettingsKeys.deepTermExpansion)
        }
        if target.termExpansionDepth != current.termExpansionDepth {
            defaults.set(target.termExpansionDepth, forKey: SettingsKeys.termExpansionDepth)
        }
        if target.theme != current.theme {
            defaults.set(target.theme, forKey: SettingsKeys.theme)
        }
        if target.readingFontFamily != current.readingFontFamily {
            defaults.set(target.readingFontFamily, forKey: SettingsKeys.readingFontFamily)
        }
        if target.readingFontSize != current.readingFontSize {
            defaults.set(target.readingFontSize, forKey: SettingsKeys.readingFontSize)
        }
        if target.readingLineHeight != current.readingLineHeight {
            defaults.set(target.readingLineHeight, forKey: SettingsKeys.readingLineHeight)
        }
        if target.readingLetterSpacing != current.readingLetterSpacing {
            defaults.set(target.readingLetterSpacing, forKey: SettingsKeys.readingLetterSpacing)
        }
        if target.citationFormat != current.citationFormat {
            defaults.set(target.citationFormat, forKey: SettingsKeys.citationFormat)
        }
        if target.citationClickAction != current.citationClickAction {
            defaults.set(target.citationClickAction, forKey: SettingsKeys.citationClickAction)
        }
        if target.originalClickAction != current.originalClickAction {
            defaults.set(target.originalClickAction, forKey: SettingsKeys.originalClickAction)
        }
        return true
    }

    private func handleDefaultsDidChange() {
        let current = Self.read(from: defaults)
        guard current != lastKnown else { return }
        lastKnown = current
        onLocalChange?(current)
    }

    private static func matchingOption(_ value: Double, allowed: [Double]) -> Double? {
        allowed.first { abs($0 - value) < 0.0001 }
    }

    private static func sanitizedOption(_ value: Double?, allowed: [Double], fallback: Double) -> Double {
        guard let value, let matched = matchingOption(value, allowed: allowed) else { return fallback }
        return matched
    }
}
