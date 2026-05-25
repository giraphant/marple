import SwiftUI

/// Layout skeleton tokens (spec §1.1 / §1.2 / §5). These values stay constant
/// across every theme — only color and font *face* become swappable later, at
/// which point these wrap into a Theme. Kept as plain namespaces for now: no
/// @Environment plumbing until theming actually carries something (spec §1.3:
/// "lightweight native, not Obsidian's 3-tier token tree").

/// Spacing scale — base unit 4pt. Pick from this everywhere; vary by zone.
enum Space {
    static let s1: CGFloat = 2
    static let s2: CGFloat = 4
    static let s3: CGFloat = 6
    static let s4: CGFloat = 8
    static let s5: CGFloat = 12
    static let s6: CGFloat = 16
    static let s7: CGFloat = 20
    static let s8: CGFloat = 24
    static let s9: CGFloat = 32
    static let s10: CGFloat = 40
}

/// UI type scale (design system v1 — "TYPE — UI (SANS)"). The `init(scale:)`
/// multiplier turns these base (标准) sizes into real point sizes, so the 界面字号
/// setting scales the whole chrome deterministically — Dynamic Type can't be
/// relied on for native macOS controls. Inject via `.environment(\.ui, …)` and
/// read with `@Environment(\.ui) private var ui`.
struct ScaledTypography: Equatable {
    var title: Font        // 17 / semibold — search field, pane titles
    var headline: Font     // 14.5 / semibold — item titles
    var body: Font         // 14 / regular — labels, previews, links
    var meta: Font         // 11 / medium — author · year
    var caption: Font      // 10 / medium — overline section heads
    var metaTracking: CGFloat  // 0.04em at the meta size
    var bodyLeading: CGFloat   // gentle line spacing for stacked body text
    var bodySize: CGFloat      // body point size, for line-height math (row height)

    init(scale: CGFloat) {
        title    = .system(size: 17 * scale, weight: .semibold)
        headline = .system(size: 14.5 * scale, weight: .semibold)
        body     = .system(size: 14 * scale, weight: .regular)
        meta     = .system(size: 11 * scale, weight: .medium)
        caption  = .system(size: 10 * scale, weight: .medium)
        metaTracking = 0.04 * 11 * scale
        bodyLeading = 3 * scale
        bodySize = 14 * scale
    }

    static let base = ScaledTypography(scale: 1)
}

private struct UITypographyKey: EnvironmentKey {
    static let defaultValue = ScaledTypography.base
}

extension EnvironmentValues {
    /// Scaled UI type scale. Read as `@Environment(\.ui) private var ui`.
    var ui: ScaledTypography {
        get { self[UITypographyKey.self] }
        set { self[UITypographyKey.self] = newValue }
    }
}

/// Reading-column metrics (spec §5).
enum Reading {
    static let measure: CGFloat = 700     // content max-width (spec 680–720)
    static let lineSpacing: CGFloat = 8   // ≈0.45×font
}
