import SwiftUI
import MarpleKit

/// Capacities-style typed icon (mirrors the web `TypeIcon`): a small rounded
/// tinted square holding the type's SF Symbol. Shared by the sidebar and the
/// command palette so the symbol/color mapping lives in one place.
extension EntryType {
    var symbolName: String {
        switch self {
        case .paper:   return "doc.text"
        case .book:    return "book"
        case .author:  return "person"
        case .topic:   return "square.stack.3d.up"
        case .journal: return "newspaper"
        case .chapter: return "list.bullet.rectangle"
        case .note:    return "note.text"
        case .image:   return "photo"
        case .other:   return "questionmark.square.dashed"
        }
    }

    var tint: Color {
        switch self {
        case .paper:   return .blue
        case .book:    return .orange
        case .author:  return .purple
        case .topic:   return .teal
        case .journal: return .green
        case .chapter: return .indigo
        case .note:    return .yellow
        case .image:   return .pink
        case .other:   return .gray
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
