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

/// Type roles = size + weight (the skeleton). Face stays system until theming.
/// Namespaced under `Typo` so it never shadows SwiftUI's own `Font.title` etc.
enum Typo {
    static let display     = Font.system(size: 28, weight: .semibold)
    static let title       = Font.system(size: 20, weight: .semibold)
    static let title3      = Font.system(size: 17, weight: .semibold)
    static let headline    = Font.system(size: 15, weight: .semibold)
    static let readingBody = Font.system(size: 17.5, weight: .regular)
    static let body        = Font.system(size: 15, weight: .regular)
    static let callout     = Font.system(size: 13, weight: .regular)
    static let subheadline = Font.system(size: 13, weight: .regular)
    static let caption     = Font.system(size: 11, weight: .medium)
    static let caption2    = Font.system(size: 10.5, weight: .medium)
}

/// Reading-column metrics (spec §5).
enum Reading {
    static let measure: CGFloat = 700     // content max-width (spec 680–720)
    static let lineSpacing: CGFloat = 8   // ≈0.45×font
}
