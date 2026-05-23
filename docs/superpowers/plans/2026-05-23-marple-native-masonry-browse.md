# Masonry Browse Grid — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the entry list a multi-column masonry (waterfall) card view that scans efficiently across ~15k entries, switchable with the existing single-column list.

**Architecture:** Add a new `EntryGridView` (peer of `EntryListView`) that renders `AppModel.visibleEntries` as a lazy masonry using the `SwiftUILazyContainer` package's `LazyVMasonry`. Card heights for column balancing come from a pure, tested `CardMetrics.estimatedHeight(for:)` in MarpleKit (keyed off `entry.preview` length, since native `Entry` has no `body_len`). A `BrowseMode` (.list/.grid) on `AppModel` toggles the content column; both modes share the same `visibleEntries`, so sort/filter/search/theme all keep working.

**Tech Stack:** Swift 6, SwiftUI, macOS 14, SwiftPM. New dep: `ciaranrobrien/SwiftUILazyContainer` (lazy masonry). Tests: swift-testing (CLT, run with the `-F` flag below).

**Conventions (this repo):**
- Build: `cd apple && swift build`
- Test: `cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks`
- Run GUI: `cd apple && swift run Marple > /tmp/marple-app.log 2>&1`
- SwiftUI views are **GUI-validated by the user at the end** (no XCTest UI tests). Only pure MarpleKit logic gets unit tests.

---

## File Structure

- Modify: `apple/Package.swift` — add `SwiftUILazyContainer` dep to the `Marple` target.
- Create: `apple/Sources/MarpleKit/CardMetrics.swift` — pure height estimate (column balancing).
- Create: `apple/Tests/MarpleKitTests/CardMetricsTests.swift` — unit tests for the estimate.
- Create: `apple/Sources/Marple/EntryCard.swift` — one card (meta · title · preview · themes).
- Create: `apple/Sources/Marple/EntryGridView.swift` — `LazyVMasonry` over `visibleEntries`.
- Modify: `apple/Sources/Marple/AppModel.swift` — add `BrowseMode` + `browseMode` property.
- Modify: `apple/Sources/Marple/MarpleApp.swift` — switch content column on `browseMode`; add a segmented list/grid toggle to the toolbar.

---

## Task 1: De-risk spike — add the package and render a trivial masonry

Confirms the third-party API and that it builds against the local toolchain **before** building the real card.

**Files:**
- Modify: `apple/Package.swift`
- Create (temporary): `apple/Sources/Marple/_MasonrySpike.swift`

- [ ] **Step 1: Add the dependency**

In `apple/Package.swift`, add to `dependencies:` (after the swift-markdown line):

```swift
        .package(url: "https://github.com/ciaranrobrien/SwiftUILazyContainer.git", branch: "main"),
```

And add the product to the `Marple` executable target:

```swift
        .executableTarget(
            name: "Marple",
            dependencies: [
                "MarpleKit",
                .product(name: "SwiftUILazyContainer", package: "SwiftUILazyContainer"),
            ]
        ),
```

(If `branch: "main"` fails to resolve, pin a tag, e.g. `from: "1.0.0"` — mirror the swift-markdown comment style.)

- [ ] **Step 2: Write a throwaway spike view**

Create `apple/Sources/Marple/_MasonrySpike.swift`:

```swift
import SwiftUI
import SwiftUILazyContainer

struct _MasonrySpike: View {
    let items = Array(0..<200)
    var body: some View {
        ScrollView {
            LazyVMasonry(items, id: \.self, columns: .adaptive(minSize: 120), spacing: 8) { i in
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .frame(height: CGFloat(40 + (i % 5) * 24))
                    .overlay(Text("\(i)").font(.caption))
            } contentHeight: { i in
                .fixed(CGFloat(40 + (i % 5) * 24))
            }
            .padding(8)
        }
        .lazyContainer()
    }
}
```

- [ ] **Step 3: Build to confirm the package + API resolve**

Run: `cd apple && swift build`
Expected: builds clean. If the `LazyVMasonry` / `.lazyContainer` signatures differ from the snippet, fix the spike to match the package's actual API, then note the correct signature for Tasks 5. (This is the whole point of the spike.)

- [ ] **Step 4: Commit the spike**

```bash
cd apple
git add Package.swift Package.resolved Sources/Marple/_MasonrySpike.swift
git commit -m "chore(native): add SwiftUILazyContainer + masonry spike"
```

- [ ] **Step 5: Delete the spike before Task 6** (note for later — remove `_MasonrySpike.swift` once `EntryGridView` exists).

---

## Task 2: CardMetrics height estimate (MarpleKit, TDD)

**Files:**
- Create: `apple/Sources/MarpleKit/CardMetrics.swift`
- Test: `apple/Tests/MarpleKitTests/CardMetricsTests.swift`

- [ ] **Step 1: Write the failing test**

Create `apple/Tests/MarpleKitTests/CardMetricsTests.swift`:

```swift
import Testing
import Foundation
@testable import MarpleKit

@Suite struct CardMetricsTests {
    private func entry(preview: String, title: String = "Title", themes: [String] = []) -> Entry {
        Entry(path: "p.md", type: .paperAnalysis, title: title, author: "A", year: "2020",
              ratingScore: 5, themes: themes, preview: preview, hasPDF: false)
    }

    @Test func longerPreviewIsTaller() {
        let short = CardMetrics.estimatedHeight(for: entry(preview: "短"))
        let long = CardMetrics.estimatedHeight(for: entry(preview: String(repeating: "字", count: 600)))
        #expect(long > short)
    }

    @Test func previewIsClamped() {
        let huge = CardMetrics.estimatedHeight(for: entry(preview: String(repeating: "x", count: 100_000)))
        #expect(huge < 400) // one giant entry must not dominate a column
    }

    @Test func emptyPreviewStillHasChrome() {
        #expect(CardMetrics.estimatedHeight(for: entry(preview: "")) > 40)
    }
}
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter CardMetricsTests`
Expected: FAIL — `CardMetrics` is undefined.

- [ ] **Step 3: Implement**

Create `apple/Sources/MarpleKit/CardMetrics.swift`:

```swift
import Foundation

/// Estimated rendered card height, used only to balance masonry columns.
/// Approximate by design: the card sizes itself at render time; this drives
/// column assignment, so a rough value is fine. Keyed off `preview` length
/// because native `Entry` has no body length.
public enum CardMetrics {
    public static func estimatedHeight(for entry: Entry, columnWidth: CGFloat = 260) -> CGFloat {
        let verticalPadding: CGFloat = 32          // 16 top + 16 bottom
        let titleLineHeight: CGFloat = 20
        let bodyLineHeight: CGFloat = 17

        let titleChars = (entry.title ?? entry.path).count
        let titlePerLine = max(1, Int(columnWidth / 9))
        let titleLines = min(2, max(1, Int(ceil(Double(titleChars) / Double(titlePerLine)))))

        let previewPerLine = max(1, Int(columnWidth / 8))
        let rawPreviewLines = Int(ceil(Double(entry.preview.count) / Double(previewPerLine)))
        let previewLines = min(12, max(0, rawPreviewLines))

        let hasMeta = (entry.author?.isEmpty == false) || (entry.year?.isEmpty == false) || entry.ratingScore > 0
        let metaHeight: CGFloat = hasMeta ? 20 : 0
        let themesHeight: CGFloat = entry.themes.isEmpty ? 0 : 22

        return verticalPadding
            + CGFloat(titleLines) * titleLineHeight
            + metaHeight
            + (previewLines > 0 ? CGFloat(previewLines) * bodyLineHeight + 6 : 0)
            + themesHeight
    }
}
```

- [ ] **Step 4: Run tests to confirm pass**

Run: `cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter CardMetricsTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
cd apple
git add Sources/MarpleKit/CardMetrics.swift Tests/MarpleKitTests/CardMetricsTests.swift
git commit -m "feat(native): card height estimate for masonry column balancing"
```

---

## Task 3: BrowseMode state on AppModel

**Files:**
- Modify: `apple/Sources/Marple/AppModel.swift`

- [ ] **Step 1: Add the enum + property**

At the top of `apple/Sources/Marple/AppModel.swift` (after the imports, before `final class AppModel`):

```swift
enum BrowseMode: String, CaseIterable, Sendable { case list, grid }
```

Inside `AppModel`, next to the other reading/browse state (e.g. after `var openPath: String?`):

```swift
    var browseMode: BrowseMode = .grid
```

(Plain `var` — no derived cache depends on it, so it needs no setter.)

- [ ] **Step 2: Build**

Run: `cd apple && swift build`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
cd apple
git add Sources/Marple/AppModel.swift
git commit -m "feat(native): add BrowseMode (list/grid) to AppModel"
```

---

## Task 4: EntryCard view

**Files:**
- Create: `apple/Sources/Marple/EntryCard.swift`

- [ ] **Step 1: Implement the card**

Create `apple/Sources/Marple/EntryCard.swift`:

```swift
import SwiftUI
import MarpleKit

struct EntryCard: View {
    let entry: Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if hasMeta {
                HStack(spacing: 6) {
                    if let a = entry.author, !a.isEmpty { Text(a).lineLimit(1) }
                    if let y = entry.year, !y.isEmpty { Text(y) }
                    Spacer(minLength: 0)
                    if entry.ratingScore > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                            Text(String(Int(entry.ratingScore.rounded()))).monospacedDigit()
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Text(entry.title ?? fallbackTitle)
                .font(.headline)
                .lineLimit(2)

            if !entry.preview.isEmpty {
                Text(entry.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(12)
            }

            if !entry.themes.isEmpty {
                Text(entry.themes.prefix(4).joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        .contentShape(Rectangle())
    }

    private var hasMeta: Bool {
        (entry.author?.isEmpty == false) || (entry.year?.isEmpty == false) || entry.ratingScore > 0
    }
    private var fallbackTitle: String {
        (entry.path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
    }
}
```

- [ ] **Step 2: Build**

Run: `cd apple && swift build`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
cd apple
git add Sources/Marple/EntryCard.swift
git commit -m "feat(native): EntryCard (meta · title · preview · themes)"
```

---

## Task 5: EntryGridView (lazy masonry)

**Files:**
- Create: `apple/Sources/Marple/EntryGridView.swift`
- Delete: `apple/Sources/Marple/_MasonrySpike.swift`

> Use the exact `LazyVMasonry` / `.lazyContainer` signature confirmed in Task 1. The code below matches the package README; adjust if Task 1 found differences.

- [ ] **Step 1: Implement the grid**

Create `apple/Sources/Marple/EntryGridView.swift`:

```swift
import SwiftUI
import MarpleKit
import SwiftUILazyContainer

struct EntryGridView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            LazyVMasonry(model.visibleEntries, columns: .adaptive(minSize: 260), spacing: 12) { entry in
                EntryCard(entry: entry)
                    .onTapGesture { Task { await model.open(entry.path) } }
            } contentHeight: { entry in
                .fixed(CardMetrics.estimatedHeight(for: entry))
            }
            .padding(16)
        }
    }
}
```

(If the package requires `.lazyContainer()` on the `ScrollView`, add it per Task 1's confirmed usage.)

- [ ] **Step 2: Remove the spike**

```bash
rm apple/Sources/Marple/_MasonrySpike.swift
```

- [ ] **Step 3: Build**

Run: `cd apple && swift build`
Expected: builds clean.

- [ ] **Step 4: Commit**

```bash
cd apple
git add Sources/Marple/EntryGridView.swift
git rm Sources/Marple/_MasonrySpike.swift
git commit -m "feat(native): EntryGridView — lazy masonry over visibleEntries"
```

---

## Task 6: Wire the list/grid toggle into the content column

**Files:**
- Modify: `apple/Sources/Marple/MarpleApp.swift`

- [ ] **Step 1: Switch the content column on browseMode + add the toggle**

In `MarpleApp.swift`, replace the `content:` closure of the `NavigationSplitView` (currently the `Group { if case .themesIndex … EntryListView }` block) with:

```swift
            } content: {
                Group {
                    if case .themesIndex = model.pane {
                        ThemesView(model: model)
                    } else if model.browseMode == .grid {
                        EntryGridView(model: model)
                    } else {
                        EntryListView(model: model)
                    }
                }
                .frame(minWidth: 320)
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        Picker("视图", selection: Binding(
                            get: { model.browseMode },
                            set: { model.browseMode = $0 }
                        )) {
                            Image(systemName: "rectangle.grid.1x2").tag(BrowseMode.list)
                            Image(systemName: "square.grid.2x2").tag(BrowseMode.grid)
                        }
                        .pickerStyle(.segmented)
                        .help("列表 / 卡片")
                    }
                }
```

(Leave the surrounding `NavigationSplitView { … } content: { … } detail: { … }` structure otherwise unchanged.)

- [ ] **Step 2: Build**

Run: `cd apple && swift build`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
cd apple
git add Sources/Marple/MarpleApp.swift
git commit -m "feat(native): list/grid view toggle in the content column"
```

---

## Task 7: Build, test, GUI validation checkpoint

- [ ] **Step 1: Full build + unit tests**

Run: `cd apple && swift build && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks`
Expected: build clean; all suites pass (existing + `CardMetricsTests`).

- [ ] **Step 2: GUI validation (user)**

Run: `cd apple && swift run Marple > /tmp/marple-app.log 2>&1`
Check:
- Content column defaults to **card masonry**; toolbar toggle flips list ⇄ grid.
- Cards show meta · title · preview · themes; **no gold-star wall**.
- Scrolling a large type (e.g. 章节 ≈ 11k) stays smooth (lazy rendering working).
- Clicking a card opens it in the reading pane; sort/filter/search/theme still affect the grid.
- Columns reflow when the window/column width changes.

- [ ] **Step 3: Commit any fixes from GUI validation**, then done.

---

## Appendix — fallback if `LazyVMasonry` doesn't fit

If Task 1 shows the package API is unworkable, replace `EntryGridView`'s body with a hand-rolled lazy masonry (no dependency):

```swift
// Split visibleEntries into N columns by shortest-running-height (using
// CardMetrics.estimatedHeight), then render each column as a LazyVStack.
ScrollView {
    HStack(alignment: .top, spacing: 12) {
        ForEach(columns.indices, id: \.self) { c in
            LazyVStack(spacing: 12) {
                ForEach(columns[c]) { entry in
                    EntryCard(entry: entry)
                        .onTapGesture { Task { await model.open(entry.path) } }
                }
            }
        }
    }
    .padding(16)
}
```

Compute `columns: [[Entry]]` in a helper (column count from `GeometryReader` width / 260; assign each entry to the currently-shortest column using `CardMetrics.estimatedHeight`) and cache it on `AppModel` like `visibleEntries`. Each column's `LazyVStack` keeps rendering lazy.
