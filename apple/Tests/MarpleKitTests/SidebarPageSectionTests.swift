import AppKit
import Testing
@testable import Marple
@testable import MarpleKit

@Suite(.serialized)
struct SidebarPageSectionTests {
    private struct LayoutCase {
        let name: String
        let hasFixed: Bool
        let hasTemporary: Bool
        let expectedRows: [String]
        let expectedDivider: Bool
    }

    @MainActor
    @Test func pageAreaRendersTheFourApprovedStates() async throws {
        let pageTitle = String(localized: "页面")
        let cases = [
            LayoutCase(name: "empty", hasFixed: false, hasTemporary: false,
                       expectedRows: [pageTitle], expectedDivider: false),
            LayoutCase(name: "temporary-only", hasFixed: false, hasTemporary: true,
                       expectedRows: [pageTitle, "Temporary"], expectedDivider: false),
            LayoutCase(name: "fixed-only", hasFixed: true, hasTemporary: false,
                       expectedRows: [pageTitle, "Fixed"], expectedDivider: false),
            LayoutCase(name: "both", hasFixed: true, hasTemporary: true,
                       expectedRows: [pageTitle, "Fixed", "Temporary"], expectedDivider: true),
        ]

        for item in cases {
            let harness = try await makeHarness(
                hasFixed: item.hasFixed,
                hasTemporary: item.hasTemporary)
            let rendered = try renderedPageArea(in: harness)

            #expect(rendered.rows == item.expectedRows, Comment(rawValue: item.name))
            #expect(rendered.dividerVisible == item.expectedDivider, Comment(rawValue: item.name))
            #expect(rendered.dividerCellExists == item.expectedDivider, Comment(rawValue: item.name))
            #expect(rendered.newTabButtonCount == 0, Comment(rawValue: item.name))
            #expect(!rendered.dividerIsGroupItem, Comment(rawValue: item.name))
            #expect(!rendered.dividerOutlineCellVisible, Comment(rawValue: item.name))
            #expect(rendered.precedingRowGap == 0, Comment(rawValue: item.name))
            if item.expectedDivider {
                #expect(rendered.dividerRowHeight == 13, Comment(rawValue: item.name))
            } else {
                #expect(rendered.dividerRowHeight == CGFloat.leastNormalMagnitude,
                        Comment(rawValue: item.name))
            }
            if item.hasTemporary {
                let expectedOffset: CGFloat = item.expectedDivider ? 13 : 0
                #expect(rendered.temporaryRowOffset == expectedOffset,
                        Comment(rawValue: item.name))
            } else {
                #expect(rendered.temporaryRowOffset == nil, Comment(rawValue: item.name))
            }
        }
    }

    @MainActor
    @Test func fixedDividerAndTemporaryRowsShareHorizontalBounds() async throws {
        let harness = try await makeHarness(hasFixed: true, hasTemporary: true)
        let outline = harness.outline
        let fixedRow = try #require(row(containing: "Fixed", in: outline))
        let temporaryRow = try #require(row(containing: "Temporary", in: outline))
        let dividerRow = temporaryRow - 1
        let fixedCell = try #require(outline.view(
            atColumn: 0, row: fixedRow, makeIfNecessary: true))
        let dividerCell = try #require(outline.view(
            atColumn: 0, row: dividerRow, makeIfNecessary: true))
        let temporaryCell = try #require(outline.view(
            atColumn: 0, row: temporaryRow, makeIfNecessary: true))
        let divider = try #require(descendants(of: NSBox.self, in: dividerCell)
            .first { $0.boxType == .separator })
        outline.layoutSubtreeIfNeeded()
        dividerCell.layoutSubtreeIfNeeded()

        #expect(fixedCell.frame.minX == dividerCell.frame.minX)
        #expect(fixedCell.frame.maxX == dividerCell.frame.maxX)
        #expect(temporaryCell.frame.minX == fixedCell.frame.minX)
        #expect(temporaryCell.frame.maxX == fixedCell.frame.maxX)
        #expect(divider.frame.minX == dividerCell.bounds.minX)
        #expect(divider.frame.maxX == dividerCell.bounds.maxX)
    }
}

extension SidebarPageSectionTests {
    @MainActor
    private struct Harness {
        let model: AppModel
        let coordinator: SidebarOutlineView.Coordinator
        let outline: NSOutlineView
    }

    @MainActor
    private struct RenderedPageArea {
        let rows: [String]
        let dividerVisible: Bool
        let dividerCellExists: Bool
        let dividerRowHeight: CGFloat
        let temporaryRowOffset: CGFloat?
        let newTabButtonCount: Int
        let dividerIsGroupItem: Bool
        let dividerOutlineCellVisible: Bool
        let precedingRowGap: CGFloat
    }

    @MainActor
    private func makeHarness(hasFixed: Bool, hasTemporary: Bool,
                             temporaryPages: [Entry] = []) async throws -> Harness {
        let fixed = entry(path: "books/fixed.md", title: "Fixed")
        let temporary = entry(path: "books/temporary.md", title: "Temporary")
        let pages = temporaryPages.isEmpty ? [temporary] : temporaryPages
        var texts = [fixed.path: "# Fixed"]
        for page in pages {
            texts[page.path] = "# Page"
        }
        let model = AppModel(client: StubVaultClient(
            entries: [fixed] + pages,
            texts: texts))
        await model.loadIndex()

        if hasFixed {
            await model.open(fixed.path)
            model.togglePin(try #require(model.activeTabID))
        }
        if hasTemporary {
            for page in pages {
                await model.openInNewTab(page.path)
            }
        }

        let collapseKey = "marple.collapsedSidebarSections"
        let defaults = UserDefaults.standard
        let previousCollapsedSections = defaults.object(forKey: collapseKey)
        defaults.set([], forKey: collapseKey)
        defer {
            if let previousCollapsedSections {
                defaults.set(previousCollapsedSections, forKey: collapseKey)
            } else {
                defaults.removeObject(forKey: collapseKey)
            }
        }

        let coordinator = SidebarOutlineView.Coordinator(model: model)
        let outline = NSOutlineView(frame: NSRect(x: 0, y: 0, width: 280, height: 600))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        column.width = 280
        outline.addTableColumn(column)
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.outlineTableColumn = column
        outline.dataSource = coordinator
        outline.delegate = coordinator
        coordinator.outlineView = outline
        coordinator.reload(outline)
        outline.deselectAll(nil)
        outline.layoutSubtreeIfNeeded()
        return Harness(model: model, coordinator: coordinator, outline: outline)
    }

    @MainActor
    private func renderedPageArea(in harness: Harness) throws -> RenderedPageArea {
        let outline = harness.outline
        let pageTitle = String(localized: "页面")
        let newTabTitle = String(localized: "新建页面")
        var rows: [String] = []
        var temporaryRow: Int?
        var newTabButtonCount = 0

        for row in 0..<outline.numberOfRows {
            guard let view = outline.view(atColumn: 0, row: row, makeIfNecessary: true) else { continue }
            let text = descendants(of: NSTextField.self, in: view).map(\.stringValue)
            if text.contains(pageTitle) { rows.append(pageTitle) }
            if text.contains("Fixed") { rows.append("Fixed") }
            if text.contains("Temporary") {
                rows.append("Temporary")
                temporaryRow = row
            }
            newTabButtonCount += descendants(of: NSButton.self, in: view)
                .filter { $0.title == newTabTitle }.count
        }

        let dividerRow = temporaryRow.map { $0 - 1 } ?? outline.numberOfRows - 1
        let dividerView = outline.view(atColumn: 0, row: dividerRow, makeIfNecessary: true)
        let dividers = dividerView.map { descendants(of: NSBox.self, in: $0) } ?? []
        let dividerRect = outline.rect(ofRow: dividerRow)
        let dividerItem = try #require(outline.item(atRow: dividerRow))

        return RenderedPageArea(
            rows: rows,
            dividerVisible: dividers.contains {
                $0.boxType == .separator && !$0.isHidden
            },
            dividerCellExists: dividerView != nil,
            dividerRowHeight: dividerRect.height,
            temporaryRowOffset: temporaryRow.map {
                outline.rect(ofRow: $0).minY - dividerRect.minY
            },
            newTabButtonCount: newTabButtonCount,
            dividerIsGroupItem: harness.coordinator.outlineView(
                outline, isGroupItem: dividerItem),
            dividerOutlineCellVisible: outline.delegate?.outlineView?(
                outline, shouldShowOutlineCellForItem: dividerItem) ?? true,
            precedingRowGap: dividerRect.minY
                - outline.rect(ofRow: dividerRow - 1).maxY)
    }

    @MainActor
    private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        var result = view.subviews.compactMap { $0 as? T }
        for child in view.subviews {
            result.append(contentsOf: descendants(of: type, in: child))
        }
        return result
    }

    @MainActor
    private func row(containing title: String, in outline: NSOutlineView) -> Int? {
        (0..<outline.numberOfRows).first { row in
            guard let view = outline.view(
                atColumn: 0, row: row, makeIfNecessary: true) else { return false }
            return descendants(of: NSTextField.self, in: view)
                .contains { $0.stringValue == title }
        }
    }

    private func entry(path: String, title: String) -> Entry {
        Entry(path: path, type: .book, title: title, author: [], year: nil,
              ratingScore: 0, themes: [], preview: "", hasPDF: false)
    }
}

@MainActor
private final class SidebarDraggingInfo: NSObject, @MainActor NSDraggingInfo {
    let draggingPasteboard: NSPasteboard

    private let location: NSPoint

    init(payloads: [String], location: NSPoint = .zero) {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("marple-sidebar-page-section-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let items = payloads.map { payload -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setString(payload, forType: SidebarDragPasteboard.tabItem)
            return item
        }
        pasteboard.writeObjects(items)
        draggingPasteboard = pasteboard
        self.location = location
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination destination: URL) -> [String]? { nil }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    func enumerateDraggingItems(
        options: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

extension SidebarPageSectionTests {
    @MainActor
    @Test func rootTemporaryDropsPreserveSingleAndBatchPositions() async throws {
        let cases = [
            (name: "single-before", localIndex: 0, sourceIndexes: [2],
             expectedPaths: ["books/c.md", "books/a.md", "books/b.md"]),
            (name: "batch-between", localIndex: 1, sourceIndexes: [0, 2],
             expectedPaths: ["books/a.md", "books/c.md", "books/b.md"]),
            (name: "single-after", localIndex: 3, sourceIndexes: [0],
             expectedPaths: ["books/b.md", "books/c.md", "books/a.md"]),
        ]

        for item in cases {
            let harness = try await makeTemporaryDropHarness()
            let temporaryTabs = harness.model.tabs.filter { !$0.pinned }
            let section = try #require(tabsSection(in: harness))
            let sectionIndex = try #require(rootIndex(of: section, in: harness))
            let info = SidebarDraggingInfo(
                payloads: item.sourceIndexes.map { "tab:\(temporaryTabs[$0].id.uuidString)" },
                location: try temporaryInsertionPoint(
                    at: item.localIndex, in: harness.outline))
            let proposedIndex = sectionIndex + item.localIndex + 1

            #expect(harness.coordinator.outlineView(
                harness.outline, validateDrop: info,
                proposedItem: nil, proposedChildIndex: proposedIndex) == .move,
                Comment(rawValue: item.name))
            #expect(harness.coordinator.outlineView(
                harness.outline, acceptDrop: info,
                item: nil, childIndex: proposedIndex),
                Comment(rawValue: item.name))
            #expect(temporaryPaths(in: harness.model) == item.expectedPaths,
                    Comment(rawValue: item.name))
        }
    }

    @MainActor
    @Test func emptyFixedSectionStillAcceptsSingleAndBatchPageDrops() async throws {
        let single = try await makeHarness(hasFixed: false, hasTemporary: false)
        let singleSection = try #require(emptyPinnedSection(in: single))
        let singleDrag = SidebarDraggingInfo(payloads: ["entry:books/fixed.md"])
        #expect(single.coordinator.outlineView(
            single.outline, validateDrop: singleDrag,
            proposedItem: singleSection, proposedChildIndex: 0) == .move)
        #expect(single.coordinator.outlineView(
            single.outline, acceptDrop: singleDrag,
            item: singleSection, childIndex: 0))
        await waitForPinnedPaths(["books/fixed.md"], in: single.model)
        #expect(pinnedPaths(in: single.model) == ["books/fixed.md"])

        let batch = try await makeHarness(hasFixed: false, hasTemporary: false)
        let batchSection = try #require(emptyPinnedSection(in: batch))
        let batchDrag = SidebarDraggingInfo(payloads: [
            "entry:books/fixed.md", "entry:books/temporary.md"
        ])
        #expect(batch.coordinator.outlineView(
            batch.outline, validateDrop: batchDrag,
            proposedItem: batchSection, proposedChildIndex: 0) == .move)
        #expect(batch.coordinator.outlineView(
            batch.outline, acceptDrop: batchDrag,
            item: batchSection, childIndex: 0))
        await waitForPinnedPaths(
            ["books/fixed.md", "books/temporary.md"], in: batch.model)
        #expect(pinnedPaths(in: batch.model) == [
            "books/fixed.md", "books/temporary.md"
        ])
    }

    @MainActor
    private func emptyPinnedSection(in harness: Harness) -> Any? {
        let possibleTitles = Set([
            String(localized: "固定页面"), String(localized: "页面")
        ])
        for row in 0..<harness.outline.numberOfRows {
            guard let item = harness.outline.item(atRow: row),
                  harness.coordinator.outlineView(
                    harness.outline, isItemExpandable: item),
                  let view = harness.outline.view(
                    atColumn: 0, row: row, makeIfNecessary: true) else { continue }
            let titles = descendants(of: NSTextField.self, in: view).map(\.stringValue)
            if !possibleTitles.isDisjoint(with: titles) { return item }
        }
        return nil
    }

    @MainActor
    private func makeTemporaryDropHarness() async throws -> Harness {
        let pages = [
            entry(path: "books/a.md", title: "A"),
            entry(path: "books/b.md", title: "B"),
            entry(path: "books/c.md", title: "C"),
        ]
        return try await makeHarness(
            hasFixed: false, hasTemporary: true, temporaryPages: pages)
    }

    @MainActor
    private func tabsSection(in harness: Harness) -> Any? {
        let count = harness.coordinator.outlineView(
            harness.outline, numberOfChildrenOfItem: nil)
        for index in 0..<count {
            let item = harness.coordinator.outlineView(
                harness.outline, child: index, ofItem: nil)
            if harness.coordinator.outlineView(
                harness.outline, heightOfRowByItem: item) == CGFloat.leastNormalMagnitude {
                return item
            }
        }
        return nil
    }

    @MainActor
    private func rootIndex(of target: Any, in harness: Harness) -> Int? {
        let count = harness.coordinator.outlineView(
            harness.outline, numberOfChildrenOfItem: nil)
        return (0..<count).first { index in
            let item = harness.coordinator.outlineView(
                harness.outline, child: index, ofItem: nil)
            return (item as AnyObject) === (target as AnyObject)
        }
    }

    @MainActor
    private func temporaryInsertionPoint(at index: Int, in outline: NSOutlineView) throws -> NSPoint {
        let rows = try ["A", "B", "C"].map {
            try #require(row(containing: $0, in: outline))
        }
        let y = index < rows.count
            ? outline.rect(ofRow: rows[index]).minY
            : outline.rect(ofRow: rows[rows.count - 1]).maxY
        return outline.convert(NSPoint(x: outline.bounds.midX, y: y), to: nil)
    }

    @MainActor
    private func pinnedPaths(in model: AppModel) -> [String] {
        model.tabs
            .filter(\.pinned)
            .compactMap { $0.identityLocation.openPath }
    }

    @MainActor
    private func temporaryPaths(in model: AppModel) -> [String] {
        model.tabs
            .filter { !$0.pinned }
            .compactMap { $0.identityLocation.openPath }
    }

    @MainActor
    private func waitForPinnedPaths(_ paths: [String], in model: AppModel) async {
        for _ in 0..<50 {
            if pinnedPaths(in: model) == paths { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
