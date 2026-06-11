import SwiftUI
import MarpleKit

/// Capacities-style typed icon (mirrors the web `TypeIcon`): a small rounded
/// tinted square holding the type's SF Symbol. Symbol + tint names come from
/// the schema declaration table (VaultSchema.active); this file only maps the
/// platform-agnostic tint name onto a SwiftUI Color.
extension EntryType {
    @MainActor var tint: Color {
        switch tintName {
        case "blue":   return .blue
        case "orange": return .orange
        case "purple": return .purple
        case "teal":   return .teal
        case "green":  return .green
        case "indigo": return .indigo
        case "yellow": return .yellow
        case "pink":   return .pink
        case "red":    return .red
        case "brown":  return .brown
        case "mint":   return .mint
        case "cyan":   return .cyan
        default:       return .gray
        }
    }
}

struct TypeBadge: View {
    let type: EntryType
    var size: CGFloat = 18

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(type.tint.opacity(0.18))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: type.symbolName)
                    .font(.system(size: size * 0.56, weight: .semibold))
                    .foregroundStyle(type.tint)
            )
    }
}
