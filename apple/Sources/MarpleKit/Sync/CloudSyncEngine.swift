import Foundation
import CloudKit

/// Observable status of the CloudKit sync engine, for UI presentation.
public enum CloudSyncStatus: Sendable, Equatable {
    case disabled(String)
    case idle(Date?)
    case syncing
    case needsInitialChoice(localSpaces: Int, remoteSpaces: Int)
    case error(String)
}

/// Protocol seam over CloudKit sync so `Library` and `SettingsSyncBridge` can be
/// unit-tested deterministically without touching Apple's CloudKit servers.
@MainActor
public protocol CloudSyncTransport: AnyObject {
    var status: CloudSyncStatus { get }
    var currentSnapshot: CloudSyncSnapshot { get }
    var hasCompletedInitialFetch: Bool { get }
    /// True when this device already completed an initial CloudKit handshake
    /// (adoption, seeding, or explicit conflict resolution) in a prior session.
    var hadPriorSyncState: Bool { get }
    var onRemoteChange: ((CloudSyncSnapshot) -> Void)? { get set }
    var onStatusChange: ((CloudSyncStatus) -> Void)? { get set }
    var onInitialFetchComplete: ((CloudSyncSnapshot) -> Void)? { get set }

    func start()
    func fetchNow()
    func enqueue(saves: [CloudSyncRecord], deletions: [String])
    func markSyncEstablished()
    func flush() async
}

/// `CKSyncEngine`-backed CloudKit Private Database sync engine shared by macOS
/// (`.readWrite`) and iOS (`.readOnly`).
///
/// Design invariants:
/// - Never initializes `CKContainer` unless `CloudSyncEntitlement.isAvailable()` is true.
/// - Waits for the first remote fetch (`hasCompletedInitialFetch`) before allowing
///   initial local seeding, preventing a fresh device from overwriting cloud data.
/// - Archives per-record CloudKit system fields (`recordChangeTag`) so saves send
///   proper versions and resolve `.serverRecordChanged` cleanly.
/// - Keeps a local cached `CloudSyncSnapshot` on disk for instant offline startup.
@MainActor
public final class CloudKitSyncEngine: CloudSyncTransport {
    public enum Mode: Sendable {
        case readWrite
        case readOnly
    }

    public private(set) var status: CloudSyncStatus
    public private(set) var currentSnapshot: CloudSyncSnapshot
    public private(set) var hasCompletedInitialFetch = false
    public let hadPriorSyncState: Bool
    public var onRemoteChange: ((CloudSyncSnapshot) -> Void)?
    public var onStatusChange: ((CloudSyncStatus) -> Void)?
    public var onInitialFetchComplete: ((CloudSyncSnapshot) -> Void)?

    private let mode: Mode
    private let containerID: String
    private let zoneID = CKRecordZone.ID(zoneName: CloudSyncConstants.zoneName, ownerName: CKCurrentUserDefaultName)
    private let storageDir: URL

    private var engine: CKSyncEngine?
    private var delegateProxy: SyncDelegateProxy?
    /// Records waiting to be uploaded (keyed by recordName) so `nextRecordZoneChangeBatch`
    /// always builds the latest payload even if multiple edits coalesced.
    private var pendingPayloads: [String: CloudSyncRecord] = [:]
    /// Archived `CKRecord.encodeSystemFields` data per recordName.
    private var archivedSystemFields: [String: Data] = [:]
    private var started = false
    private var didEnsureZone = false
    private var isInitialFetchInFlight = false

    public init(mode: Mode,
                containerID: String = CloudSyncConstants.containerIdentifier,
                storageDir: URL? = nil) {
        self.mode = mode
        self.containerID = containerID
        self.storageDir = storageDir ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Marple/CloudSync", isDirectory: true)
        let cached = Self.loadCachedSnapshot(from: self.storageDir)
        let establishedURL = self.storageDir.appendingPathComponent("sync-established.flag")
        self.hadPriorSyncState = FileManager.default.fileExists(atPath: establishedURL.path)
        self.currentSnapshot = cached ?? CloudSyncSnapshot()
        self.archivedSystemFields = Self.loadSystemFields(from: self.storageDir)
        if CloudSyncEntitlement.isAvailable(containerID: containerID) {
            self.status = .idle(nil)
        } else {
            self.status = .disabled(String(localized: "未启用 iCloud 签名（本地模式）"))
        }
    }

    public func start() {
        guard !started else { return }
        started = true
        guard CloudSyncEntitlement.isAvailable(containerID: containerID) else {
            setStatus(.disabled(String(localized: "未启用 iCloud 签名（本地模式）")))
            return
        }
        let container = CKContainer(identifier: containerID)
        let db = container.privateCloudDatabase
        let proxy = SyncDelegateProxy(owner: self)
        self.delegateProxy = proxy

        let savedState = Self.loadEngineState(from: storageDir)
        let config = CKSyncEngine.Configuration(
            database: db,
            stateSerialization: savedState,
            delegate: proxy
        )
        let syncEngine = CKSyncEngine(config)
        self.engine = syncEngine

        scheduleInitialFetch()
    }

    private func scheduleInitialFetch() {
        // Use Task.detached so calls initiated from CKSyncEngine delegate callbacks
        // (e.g. .accountChange(.signIn)) do not inherit CKSyncEngine's task-local
        // delegate context, which would trap on re-entrant `await engine.fetchChanges()`.
        Task.detached { [weak self] in
            await self?.runInitialFetch()
        }
    }

    public func fetchNow() {
        guard engine != nil else { return }
        setStatus(.syncing)
        Task.detached { [weak self] in
            await self?.performFetchNow()
        }
    }

    private func performFetchNow() async {
        guard let engine else { return }
        do {
            if mode == .readWrite, !pendingPayloads.isEmpty {
                let retries = pendingPayloads.keys.map {
                    CKSyncEngine.PendingRecordZoneChange.saveRecord(CKRecord.ID(recordName: $0, zoneID: zoneID))
                }
                engine.state.add(pendingRecordZoneChanges: retries)
                try await engine.sendChanges()
            }
            try await engine.fetchChanges()
            setStatus(.idle(Date()))
        } catch {
            handleSyncError(error, context: "拉取云端同步失败")
        }
    }

    public func enqueue(saves: [CloudSyncRecord], deletions: [String]) {
        guard mode == .readWrite, let engine else { return }
        guard !saves.isEmpty || !deletions.isEmpty else { return }

        if !didEnsureZone {
            didEnsureZone = true
            let zone = CKRecordZone(zoneID: zoneID)
            engine.state.add(pendingDatabaseChanges: [.saveZone(zone)])
        }

        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        for record in saves {
            pendingPayloads[record.recordName] = record
            currentSnapshot.apply(record)
            let recordID = CKRecord.ID(recordName: record.recordName, zoneID: zoneID)
            changes.append(.saveRecord(recordID))
        }
        for name in deletions {
            pendingPayloads.removeValue(forKey: name)
            currentSnapshot.remove(recordName: name)
            let recordID = CKRecord.ID(recordName: name, zoneID: zoneID)
            changes.append(.deleteRecord(recordID))
        }
        saveCachedSnapshot()
        engine.state.add(pendingRecordZoneChanges: changes)
    }

    public func markSyncEstablished() {
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        try? Data("1".utf8).write(to: storageDir.appendingPathComponent("sync-established.flag"), options: .atomic)
    }

    public func flush() async {
        guard mode == .readWrite, let engine else { return }
        guard !engine.state.pendingRecordZoneChanges.isEmpty || !engine.state.pendingDatabaseChanges.isEmpty else {
            return
        }
        do {
            try await engine.sendChanges()
        } catch {
            print("[marple] cloud sync flush failed: \(error)")
        }
    }

    // MARK: - Initial Fetch

    private func runInitialFetch() async {
        guard let engine, !isInitialFetchInFlight else { return }
        isInitialFetchInFlight = true
        defer { isInitialFetchInFlight = false }
        setStatus(.syncing)
        do {
            let accountStatus = try await CKContainer(identifier: containerID).accountStatus()
            guard accountStatus == .available else {
                let msg = Self.accountStatusMessage(accountStatus)
                print("[marple] cloud sync disabled: \(msg)")
                setStatus(.disabled(msg))
                hasCompletedInitialFetch = true
                return
            }
            try await engine.fetchChanges()
            hasCompletedInitialFetch = true
            setStatus(.idle(Date()))
            print("[marple] cloud sync initial fetch complete (\(currentSnapshot.spacesByID.count) spaces)")
            onInitialFetchComplete?(currentSnapshot)
        } catch {
            // Even if initial fetch fails (e.g. offline), do NOT seed/overwrite
            // remote cloud data until a real fetch succeeds.
            handleSyncError(error, context: "连接 iCloud 失败")
        }
    }

    private static func accountStatusMessage(_ status: CKAccountStatus) -> String {
        switch status {
        case .noAccount: return String(localized: "未登录 iCloud 账号")
        case .restricted: return String(localized: "iCloud 受限")
        case .couldNotDetermine: return String(localized: "无法确认 iCloud 状态")
        case .temporarilyUnavailable: return String(localized: "iCloud 暂时不可用")
        case .available: return ""
        @unknown default: return String(localized: "iCloud 不可用")
        }
    }

    // MARK: - CKSyncEngineDelegate Forwarding

    fileprivate func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) {
        switch event {
        case .stateUpdate(let update):
            Self.saveEngineState(update.stateSerialization, to: storageDir)

        case .accountChange(let change):
            switch change.changeType {
            case .signOut:
                clearLocalSyncMetadata()
                hasCompletedInitialFetch = false
                setStatus(.disabled(String(localized: "已退出 iCloud 账号")))
            case .switchAccounts:
                clearLocalSyncMetadata()
                hasCompletedInitialFetch = false
                scheduleInitialFetch()
            case .signIn:
                hasCompletedInitialFetch = false
                scheduleInitialFetch()
            @unknown default:
                break
            }

        case .fetchedDatabaseChanges(let changes):
            for deletion in changes.deletions where deletion.zoneID == zoneID {
                archivedSystemFields.removeAll()
                saveSystemFields()
                didEnsureZone = false
                currentSnapshot = CloudSyncSnapshot()
                saveCachedSnapshot()
            }

        case .fetchedRecordZoneChanges(let changes):
            var modified = false
            for modification in changes.modifications {
                let record = modification.record
                guard record.recordID.zoneID == zoneID,
                      record.recordType == CloudSyncConstants.recordType else { continue }
                archiveSystemFields(for: record)
                guard let data = record[CloudSyncConstants.payloadField] as? Data else { continue }
                let version = (record[CloudSyncConstants.schemaVersionField] as? Int64).map(Int.init) ?? 1
                do {
                    if let decoded = try CloudSyncCodec.decode(
                        recordName: record.recordID.recordName,
                        schemaVersion: version,
                        payload: data
                    ) {
                        // Do not clobber a record we currently have an unsent local edit for.
                        if pendingPayloads[decoded.recordName] == nil {
                            currentSnapshot.apply(decoded)
                            modified = true
                        }
                    }
                } catch {
                    print("[marple] cloud sync decode skipped for \(record.recordID.recordName): \(error)")
                }
            }
            for deletion in changes.deletions where deletion.recordID.zoneID == zoneID {
                let name = deletion.recordID.recordName
                archivedSystemFields.removeValue(forKey: name)
                if pendingPayloads[name] == nil {
                    currentSnapshot.remove(recordName: name)
                    modified = true
                }
            }
            saveSystemFields()
            if modified {
                saveCachedSnapshot()
                // During the initial fetch, hold delivery until `runInitialFetch`
                // finishes and invokes `onInitialFetchComplete` with the complete
                // zone snapshot — never bypass the first-connect safety check.
                if hasCompletedInitialFetch {
                    onRemoteChange?(currentSnapshot)
                }
            }

        case .sentRecordZoneChanges(let sent):
            if !sent.savedRecords.isEmpty || !sent.deletedRecordIDs.isEmpty {
                print("[marple] cloud sync uploaded: \(sent.savedRecords.count) saved, \(sent.deletedRecordIDs.count) deleted")
            }
            for saved in sent.savedRecords {
                archiveSystemFields(for: saved)
                let name = saved.recordID.recordName
                // Only clear pending payload if it matches what we just sent.
                if let pending = pendingPayloads[name],
                   let encoded = try? CloudSyncCodec.encode(pending),
                   let sentData = saved[CloudSyncConstants.payloadField] as? Data,
                   encoded.payload == sentData {
                    pendingPayloads.removeValue(forKey: name)
                }
            }
            for deletedID in sent.deletedRecordIDs {
                archivedSystemFields.removeValue(forKey: deletedID.recordName)
            }
            var retryChanges: [CKSyncEngine.PendingRecordZoneChange] = []
            var needsZone = false
            var createdConflictCopies = false
            for failed in sent.failedRecordSaves {
                let recordID = failed.record.recordID
                let code = failed.error.code
                switch code {
                case .serverRecordChanged:
                    if let serverRecord = failed.error.serverRecord {
                        archiveSystemFields(for: serverRecord)
                        if mode == .readWrite, let pending = pendingPayloads[recordID.recordName] {
                            // If two offline Macs modified the exact same Space
                            // differently, preserve the server's version as a
                            // conflict copy Space so neither Mac loses edits.
                            if case .space(let localSpace) = pending,
                               let serverData = serverRecord[CloudSyncConstants.payloadField] as? Data {
                                let ver = (serverRecord[CloudSyncConstants.schemaVersionField] as? Int64).map(Int.init) ?? 1
                                if let decoded = try? CloudSyncCodec.decode(
                                    recordName: serverRecord.recordID.recordName,
                                    schemaVersion: ver,
                                    payload: serverData
                                ), case .space(let serverSpace) = decoded, serverSpace != localSpace {
                                    let copy = serverSpace.asConflictCopy()
                                    let copyRecord = CloudSyncRecord.space(copy)
                                    pendingPayloads[copyRecord.recordName] = copyRecord
                                    currentSnapshot.apply(copyRecord)
                                    retryChanges.append(.saveRecord(CKRecord.ID(recordName: copyRecord.recordName, zoneID: zoneID)))
                                    if var meta = currentSnapshot.libraryMeta {
                                        meta.spaceOrder.append(copy.id)
                                        let metaRecord = CloudSyncRecord.libraryMeta(meta)
                                        pendingPayloads[metaRecord.recordName] = metaRecord
                                        currentSnapshot.apply(metaRecord)
                                        retryChanges.append(.saveRecord(CKRecord.ID(recordName: metaRecord.recordName, zoneID: zoneID)))
                                    }
                                    createdConflictCopies = true
                                    print("[marple] cloud sync: preserved conflict copy '\(copy.definition.name)'")
                                }
                            }
                            // Re-apply our pending payload on top of the latest server change tag.
                            retryChanges.append(.saveRecord(recordID))
                        }
                    }
                case .zoneNotFound:
                    needsZone = true
                    didEnsureZone = false
                    retryChanges.append(.saveRecord(recordID))
                case .unknownItem:
                    archivedSystemFields.removeValue(forKey: recordID.recordName)
                    retryChanges.append(.saveRecord(recordID))
                default:
                    // Revert snapshot entry so the next launch / syncNow re-attempts
                    // once the underlying server/schema error is fixed.
                    currentSnapshot.remove(recordName: recordID.recordName)
                    saveCachedSnapshot()
                    handleSyncError(failed.error, context: "上传云端同步失败")
                }
            }
            saveSystemFields()
            if createdConflictCopies {
                saveCachedSnapshot()
                onRemoteChange?(currentSnapshot)
            }
            if needsZone {
                didEnsureZone = true
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
            }
            if !retryChanges.isEmpty {
                syncEngine.state.add(pendingRecordZoneChanges: retryChanges)
            }

        case .willFetchChanges, .willSendChanges:
            setStatus(.syncing)

        case .didFetchChanges, .didSendChanges:
            if case .error = status {
                // Keep error surfaced if a failure just occurred inside this cycle.
            } else {
                setStatus(.idle(Date()))
            }

        case .sentDatabaseChanges(let sent):
            for failed in sent.failedZoneSaves {
                handleSyncError(failed.error, context: "创建云端同步区失败")
            }

        case .willFetchRecordZoneChanges, .didFetchRecordZoneChanges:
            break

        @unknown default:
            break
        }
    }

    fileprivate func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard mode == .readWrite else { return nil }
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !changes.isEmpty else { return nil }

        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { [weak self] recordID in
            await MainActor.run {
                self?.makeCKRecord(for: recordID)
            }
        }
    }

    private func makeCKRecord(for recordID: CKRecord.ID) -> CKRecord? {
        let name = recordID.recordName
        guard let payload = pendingPayloads[name] else {
            // Stale pending change after local deletion or restart without payload.
            engine?.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            return nil
        }
        guard let encoded = try? CloudSyncCodec.encode(payload) else {
            engine?.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            return nil
        }
        let record: CKRecord
        if let systemData = archivedSystemFields[name],
           let restored = Self.unarchiveRecord(from: systemData) {
            record = restored
        } else {
            record = CKRecord(recordType: CloudSyncConstants.recordType, recordID: recordID)
        }
        record[CloudSyncConstants.payloadField] = encoded.payload as CKRecordValue
        record[CloudSyncConstants.schemaVersionField] = Int64(encoded.schemaVersion) as CKRecordValue
        return record
    }

    // MARK: - Persistence Helpers

    private func setStatus(_ newStatus: CloudSyncStatus) {
        guard status != newStatus else { return }
        status = newStatus
        onStatusChange?(newStatus)
    }

    private func handleSyncError(_ error: Error, context: String) {
        let message = "\(context)：\(error.localizedDescription)"
        print("[marple] cloud sync: \(message)")
        setStatus(.error(message))
    }

    private func clearLocalSyncMetadata() {
        archivedSystemFields.removeAll()
        pendingPayloads.removeAll()
        didEnsureZone = false
        let fm = FileManager.default
        try? fm.removeItem(at: storageDir.appendingPathComponent("engine-state.bin"))
        try? fm.removeItem(at: storageDir.appendingPathComponent("system-fields.plist"))
        try? fm.removeItem(at: storageDir.appendingPathComponent("sync-established.flag"))
    }

    private func archiveSystemFields(for record: CKRecord) {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        archivedSystemFields[record.recordID.recordName] = archiver.encodedData
    }

    private static func unarchiveRecord(from data: Data) -> CKRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = true
        let record = CKRecord(coder: unarchiver)
        unarchiver.finishDecoding()
        return record
    }

    private func saveCachedSnapshot() {
        guard let data = try? JSONEncoder().encode(currentSnapshot) else { return }
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        try? data.write(to: storageDir.appendingPathComponent("snapshot.json"), options: .atomic)
    }

    private static func loadCachedSnapshot(from dir: URL) -> CloudSyncSnapshot? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("snapshot.json")) else { return nil }
        return try? JSONDecoder().decode(CloudSyncSnapshot.self, from: data)
    }

    private func saveSystemFields() {
        guard let data = try? PropertyListEncoder().encode(archivedSystemFields) else { return }
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        try? data.write(to: storageDir.appendingPathComponent("system-fields.plist"), options: .atomic)
    }

    private static func loadSystemFields(from dir: URL) -> [String: Data] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("system-fields.plist")),
              let decoded = try? PropertyListDecoder().decode([String: Data].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func saveEngineState(_ state: CKSyncEngine.State.Serialization, to dir: URL) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent("engine-state.bin"), options: .atomic)
    }

    private static func loadEngineState(from dir: URL) -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("engine-state.bin")) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }
}

/// Non-isolated delegate bridge required by `CKSyncEngineDelegate` under Swift 6
/// strict concurrency; forwards every callback cleanly onto `@MainActor`.
private final class SyncDelegateProxy: NSObject, CKSyncEngineDelegate, @unchecked Sendable {
    private weak var owner: CloudKitSyncEngine?

    init(owner: CloudKitSyncEngine) {
        self.owner = owner
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await MainActor.run { [weak owner] in
            owner?.handleEvent(event, syncEngine: syncEngine)
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard let owner else { return nil }
        return await owner.nextRecordZoneChangeBatch(context, syncEngine: syncEngine)
    }
}
