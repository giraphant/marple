import Foundation
import AppKit
import MarpleKit

/// Global handle to the active CloudKit coordinator so the SwiftUI Settings
/// scene (a separate window from the AppKit document windows) can show sync
/// status and trigger manual sync — same pattern as `ActiveBackup`.
@MainActor enum ActiveCloudSync {
    static let didChangeNotification = Notification.Name("marple.activeCloudSync.didChange")
    static var coordinator: CloudSyncCoordinator? {
        didSet { NotificationCenter.default.post(name: didChangeNotification, object: coordinator) }
    }
}

/// Coordinates bidirectional CloudKit sync for `Library` (Spaces, temporary tabs,
/// savedViews, typeOrder, hiddenTypes, activeSession) and `SettingsSyncBridge`
/// (the 11 whitelisted portable preferences).
@MainActor
final class CloudSyncCoordinator: ObservableObject {
    @Published private(set) var status: CloudSyncStatus

    private weak var library: Library?
    let settingsBridge: SettingsSyncBridge
    let transport: any CloudSyncTransport

    private var structuralWorkItem: DispatchWorkItem?
    private var activeSessionWorkItem: DispatchWorkItem?
    private var settingsWorkItem: DispatchWorkItem?
    /// Non-nil when a first-time machine already has local Spaces AND CloudKit
    /// already has different Spaces; pauses all automatic overwrites until the
    /// user explicitly chooses local vs cloud in Settings.
    private var pendingInitialRemote: CloudSyncSnapshot?
    private let structuralDebounce: TimeInterval
    private let activeSessionDebounce: TimeInterval

    init(library: Library,
         transport: any CloudSyncTransport = CloudKitSyncEngine(mode: .readWrite),
         defaults: UserDefaults = .standard,
         structuralDebounce: TimeInterval = 0.6,
         activeSessionDebounce: TimeInterval = 1.5) {
        self.library = library
        self.transport = transport
        self.settingsBridge = SettingsSyncBridge(defaults: defaults)
        self.status = transport.status
        self.structuralDebounce = structuralDebounce
        self.activeSessionDebounce = activeSessionDebounce

        transport.onStatusChange = { [weak self] newStatus in
            guard let self, self.pendingInitialRemote == nil else { return }
            self.status = newStatus
        }
        transport.onInitialFetchComplete = { [weak self] remote in
            self?.handleInitialFetchComplete(remote)
        }
        transport.onRemoteChange = { [weak self] remote in
            self?.applyRemoteSnapshot(remote)
        }
        settingsBridge.onLocalChange = { [weak self] settings in
            self?.scheduleSettingsPush(settings)
        }
    }

    func start() {
        settingsBridge.startObserving()
        transport.start()
    }

    func stop() {
        structuralWorkItem?.cancel()
        activeSessionWorkItem?.cancel()
        settingsWorkItem?.cancel()
        settingsBridge.stopObserving()
    }

    func syncNow() {
        guard pendingInitialRemote == nil else { return }
        guard transport.hasCompletedInitialFetch else {
            transport.fetchNow()
            return
        }
        pushLibraryDiffNow(includeActiveSession: true)
        pushSettingsIfChanged(settingsBridge.lastKnown)
        transport.fetchNow()
    }

    func fetchOnForeground() {
        guard pendingInitialRemote == nil else { return }
        transport.fetchNow()
    }

    /// Called by `Library` whenever Spaces, temporary tabs, views, type order,
    /// hidden types, or active document paths change locally.
    func noteLibraryChanged() {
        guard pendingInitialRemote == nil, transport.hasCompletedInitialFetch else { return }
        scheduleLibraryPush()
    }

    func flush() async {
        structuralWorkItem?.cancel()
        activeSessionWorkItem?.cancel()
        settingsWorkItem?.cancel()
        if pendingInitialRemote == nil, transport.hasCompletedInitialFetch {
            pushLibraryDiffNow(includeActiveSession: true)
            pushSettingsIfChanged(settingsBridge.lastKnown)
        }
        await transport.flush()
    }

    /// User chose "以本机为准（覆盖云端）": push this Mac's Spaces & settings and
    /// delete any stale remote Spaces that don't exist locally.
    func resolveInitialConflictUseLocal() {
        guard pendingInitialRemote != nil else { return }
        pendingInitialRemote = nil
        transport.markSyncEstablished()
        status = .syncing
        pushLibraryDiffNow(includeActiveSession: true)
        pushSettingsIfChanged(settingsBridge.lastKnown)
        Task { @MainActor [weak self] in
            await self?.transport.flush()
            self?.status = self?.transport.status ?? .idle(Date())
        }
    }

    /// User chose "以云端为准（覆盖本机）": adopt the remote CloudKit snapshot.
    func resolveInitialConflictUseRemote() {
        guard let remote = pendingInitialRemote else { return }
        pendingInitialRemote = nil
        transport.markSyncEstablished()
        library?.applyRemoteSync(remote)
        if let remoteSettings = remote.settings {
            settingsBridge.applyRemote(remoteSettings)
        }
        status = transport.status
    }

    /// User chose "合并保留两份": keep all local Spaces, append distinct remote
    /// Spaces (or conflict copies if an ID diverged), union saved views, and
    /// upload the merged result to CloudKit.
    func resolveInitialConflictMergeBoth() {
        guard let remote = pendingInitialRemote, let library else { return }
        pendingInitialRemote = nil
        transport.markSyncEstablished()
        status = .syncing
        var local = makeLocalLibrarySnapshot(from: library)
        local.settings = settingsBridge.lastKnown
        let merged = CloudSyncSnapshot.merged(local: local, remote: remote)
        library.applyRemoteSync(merged)
        let (saves, deletions) = merged.diff(from: transport.currentSnapshot)
        if !saves.isEmpty || !deletions.isEmpty {
            transport.enqueue(saves: saves, deletions: deletions)
        }
        Task { @MainActor [weak self] in
            await self?.transport.flush()
            self?.status = self?.transport.status ?? .idle(Date())
        }
    }

    // MARK: - Initial Fetch & Seeding

    private func handleInitialFetchComplete(_ remote: CloudSyncSnapshot) {
        guard let library else { return }
        let remoteHasSpaces = !remote.spacesByID.isEmpty || remote.libraryMeta != nil
        if remoteHasSpaces {
            let localPayloads = library.syncedSpacePayloads()
            let spacesDiffer = remote.orderedSpaces() != localPayloads
            if !transport.hadPriorSyncState && library.hasNonTrivialSpaces && spacesDiffer {
                // First time connecting this Mac to CloudKit, and BOTH local and
                // remote hold real Spaces: never silently overwrite the user's
                // primary machine. Pause and ask explicitly.
                pendingInitialRemote = remote
                let localCount = library.spaceDefinitions.count
                let remoteCount = remote.spacesByID.count
                print("[marple] cloud sync: initial conflict (local=\(localCount), remote=\(remoteCount)) — awaiting user choice")
                status = .needsInitialChoice(localSpaces: localCount, remoteSpaces: remoteCount)
                presentInitialConflictSheetIfInteractive(localSpaces: localCount, remoteSpaces: remoteCount)
                return
            }
            library.applyRemoteSync(remote)
            transport.markSyncEstablished()
        } else {
            transport.markSyncEstablished()
            if library.hasNonTrivialSpaces {
                pushLibraryDiffNow(includeActiveSession: true)
            }
        }

        if let remoteSettings = remote.settings {
            settingsBridge.applyRemote(remoteSettings)
        } else {
            pushSettingsIfChanged(settingsBridge.lastKnown)
        }
    }

    private func presentInitialConflictSheetIfInteractive(localSpaces: Int, remoteSpaces: Int) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        // Never call blocking `NSAlert.runModal()` synchronously inside a Swift
        // Concurrency `@MainActor` task. Defer onto the AppKit RunLoop and attach
        // a non-blocking sheet to the front window (Settings also exposes the 3 buttons).
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingInitialRemote != nil else { return }
            guard let app = NSApp,
                  let hostWindow = app.keyWindow ?? app.mainWindow ?? app.windows.first(where: { $0.isVisible }) else {
                return
            }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "首次连接 iCloud 同步")
            alert.informativeText = String(localized: "本机已有 \(localSpaces) 个空间，云端也已有 \(remoteSpaces) 个空间。为防止误覆盖，请选择同步方式：")
            alert.addButton(withTitle: String(localized: "以本机为准（覆盖云端）"))
            alert.addButton(withTitle: String(localized: "合并保留两份"))
            alert.addButton(withTitle: String(localized: "以云端为准（覆盖本机）"))
            alert.beginSheetModal(for: hostWindow) { [weak self] response in
                Task { @MainActor [weak self] in
                    switch response {
                    case .alertFirstButtonReturn:
                        self?.resolveInitialConflictUseLocal()
                    case .alertSecondButtonReturn:
                        self?.resolveInitialConflictMergeBoth()
                    case .alertThirdButtonReturn:
                        self?.resolveInitialConflictUseRemote()
                    default:
                        break
                    }
                }
            }
        }
    }

    private func applyRemoteSnapshot(_ remote: CloudSyncSnapshot) {
        guard let library, transport.hasCompletedInitialFetch else { return }
        if pendingInitialRemote != nil {
            pendingInitialRemote = remote
            status = .needsInitialChoice(
                localSpaces: library.spaceDefinitions.count,
                remoteSpaces: remote.spacesByID.count
            )
            return
        }
        if !remote.spacesByID.isEmpty || remote.libraryMeta != nil {
            library.applyRemoteSync(remote)
        }
        if let remoteSettings = remote.settings {
            settingsBridge.applyRemote(remoteSettings)
        }
    }

    // MARK: - Debounced Push

    private func scheduleLibraryPush() {
        guard let library else { return }
        let localSnapshot = makeLocalLibrarySnapshot(from: library)
        let (saves, deletions) = localSnapshot.diff(from: transport.currentSnapshot)

        let hasStructural = !deletions.isEmpty || saves.contains { record in
            if case .activeSession = record { return false }
            return true
        }
        let hasActiveOnly = saves.contains { record in
            if case .activeSession = record { return true }
            return false
        }

        if hasStructural {
            structuralWorkItem?.cancel()
            if structuralDebounce <= 0 {
                pushLibraryDiffNow(includeActiveSession: false)
            } else {
                let item = DispatchWorkItem { [weak self] in
                    self?.pushLibraryDiffNow(includeActiveSession: false)
                }
                structuralWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + structuralDebounce, execute: item)
            }
        }

        if hasActiveOnly {
            activeSessionWorkItem?.cancel()
            if activeSessionDebounce <= 0 {
                pushActiveSessionOnly()
            } else {
                let item = DispatchWorkItem { [weak self] in
                    self?.pushActiveSessionOnly()
                }
                activeSessionWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + activeSessionDebounce, execute: item)
            }
        }
    }

    private func scheduleSettingsPush(_ settings: SyncedSettings) {
        guard pendingInitialRemote == nil, transport.hasCompletedInitialFetch else { return }
        settingsWorkItem?.cancel()
        if structuralDebounce <= 0 {
            pushSettingsIfChanged(settings)
        } else {
            let item = DispatchWorkItem { [weak self] in
                self?.pushSettingsIfChanged(settings)
            }
            settingsWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + structuralDebounce, execute: item)
        }
    }

    private func pushLibraryDiffNow(includeActiveSession: Bool) {
        guard let library else { return }
        let local = makeLocalLibrarySnapshot(from: library)
        var (saves, deletions) = local.diff(from: transport.currentSnapshot)
        if !includeActiveSession {
            saves.removeAll { if case .activeSession = $0 { return true }; return false }
        }
        guard !saves.isEmpty || !deletions.isEmpty else { return }
        transport.enqueue(saves: saves, deletions: deletions)
    }

    private func pushActiveSessionOnly() {
        guard let library else { return }
        let active = library.syncedActiveSession()
        guard !active.hasSamePaths(as: transport.currentSnapshot.activeSession) else { return }
        transport.enqueue(saves: [.activeSession(active)], deletions: [])
    }

    private func pushSettingsIfChanged(_ settings: SyncedSettings) {
        guard transport.currentSnapshot.settings != settings else { return }
        transport.enqueue(saves: [.settings(settings)], deletions: [])
    }

    private func makeLocalLibrarySnapshot(from library: Library) -> CloudSyncSnapshot {
        let payloads = library.syncedSpacePayloads()
        let byID = Dictionary(payloads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return CloudSyncSnapshot(
            spacesByID: byID,
            libraryMeta: library.syncedLibraryMeta(),
            settings: transport.currentSnapshot.settings,
            activeSession: library.syncedActiveSession()
        )
    }
}
