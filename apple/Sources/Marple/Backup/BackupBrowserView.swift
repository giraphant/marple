import SwiftUI
import AppKit
import MarpleKit

/// Opens (and reuses) a single browser window. Lives outside the SwiftUI Settings
/// scene because it's a free-standing utility window, like the main app window.
@MainActor
final class BackupBrowserPresenter {
    static let shared = BackupBrowserPresenter()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        guard let scheduler = ActiveBackup.scheduler else { return }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        w.title = String(localized: "浏览备份")
        w.contentViewController = NSHostingController(rootView: BackupBrowserView(scheduler: scheduler))
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

/// Browse snapshots → pick a document → restore it as a side copy (never
/// overwrites the live file). Reads the live `SnapshotStore` via `ActiveBackup`.
struct BackupBrowserView: View {
    @ObservedObject private var scheduler: BackupScheduler
    @State private var snapshots: [SnapshotStore.Snapshot] = []
    @State private var selected: SnapshotStore.Snapshot?
    @State private var documents: [String] = []
    @State private var status: String?

    private var store: SnapshotStore { scheduler.store }

    init(scheduler: BackupScheduler) {
        self.scheduler = scheduler
    }

    var body: some View {
        HSplitView {
            snapshotList
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 300)
            documentPane
                .frame(minWidth: 360)
        }
        .frame(minWidth: 640, minHeight: 380)
        .onAppear(perform: reload)
        .onReceive(scheduler.$lastBackup) { _ in reload() }
    }

    private var snapshotList: some View {
        List(snapshots, id: \.date, selection: Binding(
            get: { selected?.date },
            set: { newDate in
                selected = snapshots.first { $0.date == newDate }
                documents = selected.map { store.documents(in: $0) } ?? []
                status = nil
            })
        ) {
            Text(Self.friendly($0.date)).tag($0.date)
        }
        .overlay {
            if snapshots.isEmpty {
                ContentUnavailableView("暂无备份", systemImage: "clock.arrow.circlepath",
                                       description: Text("文库发生变动后会自动生成快照。"))
            }
        }
    }

    @ViewBuilder
    private var documentPane: some View {
        if let snapshot = selected {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(Self.friendly(snapshot.date)).font(.headline)
                    Spacer()
                    Button("在 Finder 中打开此快照") { reveal(snapshot) }
                }
                .padding(12)
                Divider()
                List(documents, id: \.self) { rel in
                    HStack {
                        Text(displayName(rel)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("恢复为副本") { restore(snapshot, rel) }
                            .controlSize(.small)
                    }
                }
                if let status {
                    Divider()
                    Text(status).font(.caption).foregroundStyle(.secondary).padding(12)
                }
            }
        } else {
            ContentUnavailableView("选择一个快照", systemImage: "sidebar.left")
        }
    }

    // MARK: - Actions

    private func reload() {
        snapshots = store.list()
        if let sel = selected {
            if snapshots.contains(where: { $0.date == sel.date }) {
                documents = store.documents(in: sel)
            } else {
                selected = nil
                documents = []
            }
        }
    }

    private func restore(_ snapshot: SnapshotStore.Snapshot, _ rel: String) {
        do {
            let newRel = try store.restoreCopy(snapshot: snapshot, relPath: rel)
            status = String(localized: "已恢复为副本：\(newRel)")
        } catch {
            status = String(localized: "恢复失败：\(error.localizedDescription)")
        }
    }

    private func reveal(_ snapshot: SnapshotStore.Snapshot) {
        NSWorkspace.shared.activateFileViewerSelecting([snapshot.url])
    }

    private func displayName(_ rel: String) -> String {
        rel.hasPrefix("vault/") ? String(rel.dropFirst("vault/".count)) : rel
    }

    private static func friendly(_ date: Date) -> String {
        AppDateFormatters.friendlyMinute.string(from: date)
    }
}
