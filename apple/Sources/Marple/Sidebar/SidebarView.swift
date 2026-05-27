import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            SidebarOutlineView(model: model)
            if let label = statusLabel {
                Divider()
                BootStatusRow(label: label)
            }
        }
        .navigationTitle("Marple")
    }

    /// What the sidebar footer should say, if anything. Bootstrap wins over
    /// refresh — during cold start both flags can be true momentarily, and
    /// "正在建立索引…" is the more accurate user-facing wording for that. The
    /// footer disappears entirely when neither flag is set. QUA-105.
    private var statusLabel: String? {
        if model.isBootstrapping { return "正在建立索引…" }
        if model.isRefreshing { return "正在更新索引…" }
        return nil
    }
}

/// NetNewsWire/Mail-style sidebar footer: small spinning indicator + secondary
/// label, no border, sits flush at the bottom. Visible only while indexing or
/// refreshing — the divider above it is what separates it from the list.
private struct BootStatusRow: View {
    let label: String
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
                .frame(width: 14, height: 14)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
