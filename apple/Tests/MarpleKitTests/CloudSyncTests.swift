import Foundation
import Testing
@testable import Marple
@testable import MarpleKit

@MainActor
private final class MockCloudSyncTransport: CloudSyncTransport {
    var status: CloudSyncStatus = .idle(nil)
    var currentSnapshot = CloudSyncSnapshot()
    var hasCompletedInitialFetch = false
    var hadPriorSyncState = false
    var onRemoteChange: ((CloudSyncSnapshot) -> Void)?
    var onStatusChange: ((CloudSyncStatus) -> Void)?
    var onInitialFetchComplete: ((CloudSyncSnapshot) -> Void)?

    var startCalls = 0
    var fetchNowCalls = 0
    var flushCalls = 0
    var establishedCalls = 0
    var enqueuedBatches: [(saves: [CloudSyncRecord], deletions: [String])] = []

    func start() { startCalls += 1 }
    func fetchNow() { fetchNowCalls += 1 }
    func markSyncEstablished() { establishedCalls += 1 }
    func flush() async { flushCalls += 1 }

    func enqueue(saves: [CloudSyncRecord], deletions: [String]) {
        enqueuedBatches.append((saves, deletions))
        for record in saves { currentSnapshot.apply(record) }
        for name in deletions { currentSnapshot.remove(recordName: name) }
    }

    /// Mirrors real `CKSyncEngine` order: `.fetchedRecordZoneChanges` fires
    /// during `fetchChanges()` BEFORE `hasCompletedInitialFetch` becomes true
    /// and `onInitialFetchComplete` fires.
    func completeInitialFetch(with remote: CloudSyncSnapshot) {
        currentSnapshot = remote
        onRemoteChange?(remote)
        hasCompletedInitialFetch = true
        onInitialFetchComplete?(remote)
    }

    func deliverRemoteChange(_ remote: CloudSyncSnapshot) {
        currentSnapshot = remote
        onRemoteChange?(remote)
    }
}

@MainActor
@Suite struct CloudSyncTests {
    static let entries: [Entry] = [
        Entry(path: "vault/papers/a.md", type: .paper, title: "Paper Alpha", author: [], year: "2024",
              ratingScore: 0, themes: [], preview: "", hasPDF: false),
        Entry(path: "vault/papers/b.md", type: .paper, title: "Paper Beta", author: [], year: "2025",
              ratingScore: 0, themes: [], preview: "", hasPDF: false),
        Entry(path: "vault/notes/c.md", type: .note, title: "Note Gamma", author: [], year: "2026",
              ratingScore: 0, themes: [], preview: "", hasPDF: false),
    ]

    private func makeLibrary(defaults: UserDefaults) -> Library {
        let texts = Dictionary(uniqueKeysWithValues: Self.entries.map { ($0.path, "# \($0.title ?? "")") })
        return Library(client: StubVaultClient(entries: Self.entries, texts: texts),
                       stateStore: nil, searchDefaults: defaults)
    }

    // MARK: - Codec & Path Validation

    @Test func spacePayloadRoundTripsAndOmitsDerivedCachesAndListContext() throws {
        let spaceID = UUID()
        let itemID = UUID()
        let groupID = UUID()
        let tempID = UUID()
        let listCtx = ListContext(searchText: "secret-query", filters: [], filterMatch: .all, sorts: [])
        let def = SpaceDefinition(
            id: spaceID,
            name: "研究",
            iconName: "books.vertical",
            isArchived: false,
            roots: [
                .group(.init(id: groupID, name: "待读", children: [
                    .item(.init(
                        id: itemID,
                        home: NavLocation(pane: .type(.paper), openPath: "vault/papers/a.md", listContext: listCtx),
                        customTitle: "重点论文",
                        cachedTitle: "Stale Cached Title",
                        cachedType: .paper
                    ))
                ]))
            ]
        )
        let temp = SyncedTemporaryTab(
            id: tempID,
            pane: .type(.note),
            openPath: "vault/notes/c.md",
            customTitle: nil
        )
        let payload = SyncedSpacePayload(definition: def, temporaryTabs: [temp])
        let encoded = try CloudSyncCodec.encode(.space(payload))
        let jsonString = String(decoding: encoded.payload, as: UTF8.self)
        #expect(!jsonString.contains("secret-query"))
        #expect(!jsonString.contains("Stale Cached Title"))

        let decoded = try CloudSyncCodec.decode(
            recordName: encoded.recordName,
            schemaVersion: encoded.schemaVersion,
            payload: encoded.payload
        )
        guard case .space(let roundTripped) = decoded else {
            Issue.record("Expected decoded .space record")
            return
        }
        #expect(roundTripped == payload)
        #expect(roundTripped.definition.items.first?.cachedTitle == nil)
        #expect(roundTripped.definition.items.first?.home.listContext == nil)
    }

    @Test func codecRejectsUnsafePathsAndHigherSchemaVersions() throws {
        let spaceID = UUID()
        let badPaths = ["/Users/me/secret.md", "~/vault/a.md", "vault/../etc/passwd", "file:///a.md"]
        for bad in badPaths {
            let def = SpaceDefinition(
                id: spaceID, name: "Bad",
                roots: [.item(.init(id: UUID(), home: NavLocation(pane: .type(.paper), openPath: bad)))]
            )
            #expect(throws: CloudSyncCodecError.invalidPath(bad)) {
                _ = try CloudSyncCodec.encode(.space(SyncedSpacePayload(definition: def)))
            }
        }

        let valid = try CloudSyncCodec.encode(.settings(SyncedSettings()))
        #expect(throws: CloudSyncCodecError.unsupportedSchemaVersion(99)) {
            _ = try CloudSyncCodec.decode(recordName: valid.recordName, schemaVersion: 99, payload: valid.payload)
        }
    }

    @Test func diffOnlyEmitsChangedRecordsAndIsolatesActiveSession() {
        let spaceA = SyncedSpacePayload(definition: SpaceDefinition(id: UUID(), name: "A"))
        let spaceB = SyncedSpacePayload(definition: SpaceDefinition(id: UUID(), name: "B"))
        let base = CloudSyncSnapshot(
            spacesByID: [spaceA.id: spaceA, spaceB.id: spaceB],
            libraryMeta: SyncedLibraryMeta(spaceOrder: [spaceA.id, spaceB.id], savedViews: [],
                                           typeOrder: EntryType.modeled, hiddenTypes: []),
            settings: SyncedSettings(),
            activeSession: SyncedActiveSession(updatedAtMs: 100, activePathBySpace: [spaceA.id.uuidString: "vault/papers/a.md"])
        )

        // Clicking a different tab changes ONLY activeSession, never Space records.
        var afterClick = base
        afterClick.activeSession = SyncedActiveSession(
            updatedAtMs: 200,
            activePathBySpace: [spaceA.id.uuidString: "vault/papers/b.md"]
        )
        let clickDiff = afterClick.diff(from: base)
        #expect(clickDiff.deletions.isEmpty)
        #expect(clickDiff.saves.count == 1)
        if case .activeSession = clickDiff.saves.first {} else {
            Issue.record("Expected only activeSession in diff after tab click")
        }

        // Editing Space A touches ONLY space-<A>, leaving Space B untouched.
        var afterEditA = base
        var editedA = spaceA
        editedA.definition.name = "A Renamed"
        afterEditA.spacesByID[spaceA.id] = editedA
        let editDiff = afterEditA.diff(from: base)
        #expect(editDiff.deletions.isEmpty)
        #expect(editDiff.saves == [.space(editedA)])
    }

    // MARK: - Settings Whitelist & Loop Prevention

    @Test func settingsBridgeOnlySyncs11WhitelistedKeysAndIgnoresSecrets() throws {
        let suite = testDefaultsSuite("cloud-settings")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // Populate sensitive / local-only keys with recognizable sentinels.
        defaults.set("/Users/secret/vault", forKey: "marple.workspaceRoot")
        defaults.set("/usr/local/bin/quasi", forKey: SettingsKeys.quasiExecutablePath)
        defaults.set("TOKEN_12345", forKey: SettingsKeys.aiDispatchTemplate)
        defaults.set("claude --api-key=SECRET", forKey: SettingsKeys.readerAIAgent)
        defaults.set("private prompt text", forKey: SettingsKeys.readerAIReanalyzePrompt)
        defaults.set(true, forKey: SettingsKeys.cliServerEnabled)
        defaults.set("/private/backups", forKey: SettingsKeys.backupLocation)

        // Set portable whitelisted keys.
        defaults.set(ThemePreference.dark.rawValue, forKey: SettingsKeys.theme)
        defaults.set(ReadingFontFamily.sourceHanSerif.rawValue, forKey: SettingsKeys.readingFontFamily)
        defaults.set(18.0, forKey: SettingsKeys.readingFontSize)
        defaults.set(true, forKey: SettingsKeys.balancedTermExpansion)
        defaults.set(4, forKey: SettingsKeys.termExpansionDepth)

        let synced = SettingsSyncBridge.read(from: defaults)
        let encoded = try CloudSyncCodec.encode(.settings(synced))
        let json = String(decoding: encoded.payload, as: UTF8.self)

        #expect(!json.contains("TOKEN_12345"))
        #expect(!json.contains("SECRET"))
        #expect(!json.contains("/Users/secret"))
        #expect(!json.contains("private prompt"))
        #expect(!json.contains("/private/backups"))
        #expect(!json.contains("cliServerEnabled"))

        #expect(synced.theme == "dark")
        #expect(synced.readingFontFamily == "sourceHanSerif")
        #expect(synced.readingFontSize == 18.0)
        #expect(synced.balancedTermExpansion == true)
        #expect(synced.termExpansionDepth == 4)

        // Applying remote settings produces zero echo callbacks and rejects invalid enum values.
        let bridge = SettingsSyncBridge(defaults: defaults)
        var echoCount = 0
        bridge.onLocalChange = { _ in echoCount += 1 }
        bridge.startObserving()
        defer { bridge.stopObserving() }

        var remote = synced
        remote.theme = "light"
        remote.readingFontFamily = "futureUnknownFont"  // should be ignored, keeping sourceHanSerif
        remote.citationFormat = CitationFormat.inlineZH.rawValue
        let changed = bridge.applyRemote(remote)
        #expect(changed)
        #expect(defaults.string(forKey: SettingsKeys.theme) == "light")
        #expect(defaults.string(forKey: SettingsKeys.readingFontFamily) == "sourceHanSerif")
        #expect(defaults.string(forKey: SettingsKeys.citationFormat) == "inline-zh")
        #expect(echoCount == 0)
    }

    // MARK: - Coordinator Bootstrap & Remote Rebase

    @Test func freshDeviceAdoptsRemoteSpacesWithoutOverwritingCloud() async throws {
        let suite = testDefaultsSuite("cloud-fresh")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let library = makeLibrary(defaults: defaults)
        let window = AppModel(library: library)
        await window.loadIndex()

        let transport = MockCloudSyncTransport()
        let coordinator = CloudSyncCoordinator(
            library: library,
            transport: transport,
            defaults: defaults,
            structuralDebounce: 0,
            activeSessionDebounce: 0
        )
        library.onSyncStateChanged = { [weak coordinator] in coordinator?.noteLibraryChanged() }
        coordinator.start()

        // Before initial fetch completes, a fresh Mac must NOT push its default empty Space.
        #expect(transport.enqueuedBatches.isEmpty)

        // Cloud delivers an existing Space + dark theme.
        let remoteSpaceID = UUID()
        let pinnedID = UUID()
        let tempID = UUID()
        let remoteSpace = SyncedSpacePayload(
            definition: SpaceDefinition(
                id: remoteSpaceID,
                name: "博士论文",
                iconName: "graduationcap",
                roots: [.item(.init(id: pinnedID, home: NavLocation(pane: .type(.paper), openPath: "vault/papers/a.md"), customTitle: "核心文献"))]
            ),
            temporaryTabs: [SyncedTemporaryTab(id: tempID, pane: .type(.note), openPath: "vault/notes/c.md")]
        )
        let remoteView = SavedView(name: "近期论文", clauses: [], match: .all, sorts: [])
        let remoteSnapshot = CloudSyncSnapshot(
            spacesByID: [remoteSpaceID: remoteSpace],
            libraryMeta: SyncedLibraryMeta(
                spaceOrder: [remoteSpaceID],
                savedViews: [remoteView],
                typeOrder: EntryType.modeled,
                hiddenTypes: [.webpage]
            ),
            settings: SyncedSettings(theme: "dark", readingFontSize: 17)
        )

        transport.completeInitialFetch(with: remoteSnapshot)

        // Fresh Mac adopted cloud Spaces, temporary tabs, saved views, hidden types, and settings — with ZERO echo writes!
        #expect(library.spaceDefinitions.map(\.id) == [remoteSpaceID])
        #expect(library.spaceDefinitions.first?.name == "博士论文")
        #expect(window.spaces.first?.workspace?.tabs.map(\.id) == [pinnedID, tempID])
        #expect(library.savedViews.map(\.id) == [remoteView.id])
        #expect(library.hiddenTypes == [.webpage])
        #expect(defaults.string(forKey: SettingsKeys.theme) == "dark")
        #expect(defaults.double(forKey: SettingsKeys.readingFontSize) == 17)
        #expect(transport.enqueuedBatches.isEmpty)
    }

    @Test func emptyCloudDoesNotSeedFreshDefaultSpaceUntilUserEdits() async throws {
        let suite = testDefaultsSuite("cloud-empty")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let library = makeLibrary(defaults: defaults)
        let window = AppModel(library: library)
        await window.loadIndex()

        let transport = MockCloudSyncTransport()
        let coordinator = CloudSyncCoordinator(
            library: library,
            transport: transport,
            defaults: defaults,
            structuralDebounce: 0,
            activeSessionDebounce: 0
        )
        library.onSyncStateChanged = { [weak coordinator] in coordinator?.noteLibraryChanged() }
        coordinator.start()

        // Cloud is empty; fresh install has only an untouched default Space.
        transport.completeInitialFetch(with: CloudSyncSnapshot())
        let seededSpaces = transport.enqueuedBatches.flatMap(\.saves).filter {
            if case .space = $0 { return true }; return false
        }
        #expect(seededSpaces.isEmpty)

        // Once the user opens a tab, that Space now syncs.
        await window.openInNewTab("vault/papers/a.md")
        let pushedSpaces = transport.enqueuedBatches.flatMap(\.saves).compactMap { record -> SyncedSpacePayload? in
            if case .space(let s) = record { return s }; return nil
        }
        #expect(!pushedSpaces.isEmpty)
        #expect(pushedSpaces.last?.temporaryTabs.first?.openPath == "vault/papers/a.md")
    }

    @Test func primaryMachineWithExistingLocalSpacesIsNeverSilentlyOverwrittenOnFirstConnect() async throws {
        let suite = testDefaultsSuite("cloud-conflict")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let library = makeLibrary(defaults: defaults)
        let window = AppModel(library: library)
        await window.loadIndex()
        // Primary Mac already has real local tabs/Spaces before ever connecting CloudKit.
        await window.openInNewTab("vault/papers/a.md")
        let localSpaceID = try #require(library.spaceDefinitions.first?.id)

        let transport = MockCloudSyncTransport()
        transport.hadPriorSyncState = false
        let coordinator = CloudSyncCoordinator(
            library: library,
            transport: transport,
            defaults: defaults,
            structuralDebounce: 0,
            activeSessionDebounce: 0
        )
        coordinator.start()

        // Cloud already holds stale Spaces from a secondary Mac.
        let staleRemoteID = UUID()
        let remote = CloudSyncSnapshot(
            spacesByID: [
                staleRemoteID: SyncedSpacePayload(
                    definition: SpaceDefinition(id: staleRemoteID, name: "旧副机空间")
                )
            ],
            libraryMeta: SyncedLibraryMeta(
                spaceOrder: [staleRemoteID], savedViews: [],
                typeOrder: EntryType.modeled, hiddenTypes: []
            ),
            settings: SyncedSettings(theme: "dark")
        )
        transport.completeInitialFetch(with: remote)

        // Local primary Spaces MUST remain untouched and coordinator asks the user explicitly.
        #expect(library.spaceDefinitions.map(\.id) == [localSpaceID])
        #expect(coordinator.status == .needsInitialChoice(localSpaces: 1, remoteSpaces: 1))
        #expect(transport.enqueuedBatches.isEmpty)

        // Choosing "use local" overwrites cloud and deletes the stale remote Space.
        coordinator.resolveInitialConflictUseLocal()
        let deleted = transport.enqueuedBatches.flatMap(\.deletions)
        #expect(deleted.contains(CloudSyncConstants.spaceRecordPrefix + staleRemoteID.uuidString))
        #expect(transport.currentSnapshot.spacesByID[localSpaceID] != nil)
        #expect(transport.currentSnapshot.spacesByID[staleRemoteID] == nil)
    }

    @Test func conflictCopyAssignsFreshDisjointUUIDsAndMergeBothPreservesAllSpaces() async throws {
        let sharedID = UUID()
        let itemID = UUID()
        let groupID = UUID()
        let tempID = UUID()
        let original = SyncedSpacePayload(
            definition: SpaceDefinition(
                id: sharedID, name: "研究",
                roots: [.group(.init(id: groupID, name: "G", children: [
                    .item(.init(id: itemID, home: NavLocation(pane: .type(.paper), openPath: "vault/papers/a.md")))
                ]))]
            ),
            temporaryTabs: [SyncedTemporaryTab(id: tempID, pane: .type(.note), openPath: "vault/notes/c.md")]
        )
        let copy = original.asConflictCopy()
        #expect(copy.id != original.id)
        #expect(copy.definition.name == "研究（冲突副本）")
        #expect(copy.definition.items.first?.id != itemID)
        if case .group(let g) = copy.definition.roots.first {
            #expect(g.id != groupID)
        } else {
            Issue.record("Expected group in conflict copy")
        }
        #expect(copy.temporaryTabs.first?.id != tempID)

        // Merge both: local space + same-ID diverged remote space + distinct remote space.
        let remoteOnlyID = UUID()
        let divergedRemote = SyncedSpacePayload(
            definition: SpaceDefinition(id: sharedID, name: "研究-云端版")
        )
        let remoteOnly = SyncedSpacePayload(
            definition: SpaceDefinition(id: remoteOnlyID, name: "副机独立空间")
        )
        let localSnap = CloudSyncSnapshot(
            spacesByID: [sharedID: original],
            libraryMeta: SyncedLibraryMeta(spaceOrder: [sharedID], savedViews: [],
                                           typeOrder: EntryType.modeled, hiddenTypes: [])
        )
        let remoteSnap = CloudSyncSnapshot(
            spacesByID: [sharedID: divergedRemote, remoteOnlyID: remoteOnly],
            libraryMeta: SyncedLibraryMeta(spaceOrder: [sharedID, remoteOnlyID], savedViews: [],
                                           typeOrder: EntryType.modeled, hiddenTypes: [])
        )

        let merged = CloudSyncSnapshot.merged(local: localSnap, remote: remoteSnap)
        #expect(merged.spacesByID.count == 3)
        let names = merged.orderedSpaces().map(\.definition.name)
        #expect(names == ["研究", "研究-云端版（冲突副本）", "副机独立空间"])

        // End-to-end coordinator "merge both" keeps local Space and imports remote Space.
        let suite = testDefaultsSuite("cloud-merge-both")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = makeLibrary(defaults: defaults)
        let window = AppModel(library: library)
        await window.loadIndex()
        await window.openInNewTab("vault/papers/a.md")
        let localID = try #require(library.spaceDefinitions.first?.id)

        let transport = MockCloudSyncTransport()
        let coordinator = CloudSyncCoordinator(
            library: library, transport: transport, defaults: defaults,
            structuralDebounce: 0, activeSessionDebounce: 0
        )
        coordinator.start()
        transport.completeInitialFetch(with: CloudSyncSnapshot(
            spacesByID: [remoteOnlyID: remoteOnly],
            libraryMeta: SyncedLibraryMeta(spaceOrder: [remoteOnlyID], savedViews: [],
                                           typeOrder: EntryType.modeled, hiddenTypes: [])
        ))
        #expect(coordinator.status == .needsInitialChoice(localSpaces: 1, remoteSpaces: 1))

        coordinator.resolveInitialConflictMergeBoth()
        #expect(library.spaceDefinitions.map(\.id) == [localID, remoteOnlyID])
        #expect(transport.currentSnapshot.spacesByID[localID] != nil)
        #expect(transport.currentSnapshot.spacesByID[remoteOnlyID] != nil)
    }

    // MARK: - iOS Resolution from CloudSyncSnapshot

    @Test func sessionResolverDirectlyResolvesCloudSnapshotWithLiveEntryTitles() {
        let activeID = UUID()
        let archivedID = UUID()
        let snapshot = CloudSyncSnapshot(
            spacesByID: [
                activeID: SyncedSpacePayload(
                    definition: SpaceDefinition(
                        id: activeID,
                        name: "主空间",
                        iconName: "star",
                        isArchived: false,
                        roots: [
                            .item(.init(id: UUID(), home: NavLocation(pane: .type(.paper), openPath: "vault/papers/a.md"), customTitle: nil)),
                            .group(.init(id: UUID(), name: "精选", children: [
                                .item(.init(id: UUID(), home: NavLocation(pane: .type(.paper), openPath: "vault/papers/b.md"), customTitle: "自定义别名"))
                            ]))
                        ]
                    ),
                    temporaryTabs: [
                        // Duplicate of pinned a.md should be deduped; c.md should appear with live title.
                        SyncedTemporaryTab(id: UUID(), pane: .type(.paper), openPath: "vault/papers/a.md"),
                        SyncedTemporaryTab(id: UUID(), pane: .type(.note), openPath: "vault/notes/c.md"),
                    ]
                ),
                archivedID: SyncedSpacePayload(
                    definition: SpaceDefinition(
                        id: archivedID, name: "已归档", isArchived: true,
                        roots: [.item(.init(id: UUID(), home: NavLocation(pane: .type(.paper), openPath: "vault/papers/a.md")))]
                    )
                ),
            ],
            libraryMeta: SyncedLibraryMeta(spaceOrder: [activeID, archivedID], savedViews: [],
                                           typeOrder: EntryType.modeled, hiddenTypes: []),
            activeSession: SyncedActiveSession(updatedAtMs: 12345, activePathBySpace: [activeID.uuidString: "vault/papers/b.md"])
        )

        let resolved = SessionResolver.resolve(snapshot, entries: Self.entries)
        #expect(resolved.count == 1)
        let space = resolved[0]
        #expect(space.id == activeID)
        #expect(space.activePath == "vault/papers/b.md")
        #expect(space.roots.count == 3) // a.md (pinned), 精选 group, c.md (temp)
        if case .doc(_, let entry, let label) = space.roots[0] {
            #expect(entry.path == "vault/papers/a.md")
            #expect(label == "Paper Alpha")
        } else {
            Issue.record("Expected first root to be pinned doc a.md")
        }
        if case .group(_, let name, _, let kids) = space.roots[1] {
            #expect(name == "精选")
            if case .doc(_, _, let label) = kids.first {
                #expect(label == "自定义别名")
            } else {
                Issue.record("Expected doc inside group")
            }
        } else {
            Issue.record("Expected second root to be group 精选")
        }
        if case .doc(_, let entry, let label) = space.roots[2] {
            #expect(entry.path == "vault/notes/c.md")
            #expect(label == "Note Gamma")
        } else {
            Issue.record("Expected third root to be temp doc c.md")
        }
    }
}
