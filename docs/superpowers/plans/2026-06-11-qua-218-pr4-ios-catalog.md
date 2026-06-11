# QUA-218 PR4 — iOS 接 Catalog：双端最大化互通（真平台无关验收）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`).

**Goal:** 把 iOS reader 的"平行派生逻辑"(B 类)全部收进 MarpleKit/Catalog——session 解析下沉为共享 `SessionResolver`、searchIndex 生命周期改由 Catalog 驱动、刷新单飞改用 `catalog.refresh`——使 iOS 结构上与 Mac 一样消费同一核心,iOS 壳只剩真平台边界胶水。这是 spec §6.4「真平台无关验收」。

**Architecture:** iOS `ReaderModel`（`@MainActor @Observable`，与 Mac AppModel 同形）持一个 `Catalog`，entries 变动调 `catalog.rebuildIndexDerived(entries:savedViews:[])`，搜索读 `catalog.searchIndex`。Mac 写的 open-tabs.json 由新的 MarpleKit `SessionResolver` 解析（iOS 直接用其返回的 `Identifiable` 类型渲染）。iOS 的 reconcile→index→derive 包进 `catalog.refresh(body:)`，复用 RefreshAuthority 合流+generation，删手卷 `refreshing` 布尔。**iOS 专属边界胶水保持原样**：security-scoped bookmark、iCloud materialize、文件夹选取、phase/progress 启动 UX、容器 DB 路径——它们没有 Mac twin，不是分叉风险。

**Tech Stack:** Swift 6 / swift-testing / xcodegen + xcodebuild（iOS）。`apple/.build` 符号链接**永不删**。`Identifiable` 是 Swift 标准库（非 SwiftUI），故解析输出类型可住 MarpleKit。iOS 构建见 CLAUDE.md §6（`xcodebuild -downloadPlatform iOS` 一次性）。

---

## 计划级决策（已定，用户已批准"iOS 接全 Catalog / 双端互通"）

1. **三步收 B 类**：(B) session 解析→MarpleKit `SessionResolver`；(A) searchIndex→`catalog.searchIndex`；(C) 刷新单飞→`catalog.refresh`。A/B/C 各一个独立任务。
2. **searchIndex 时序变更（唯一行为差异，可接受并记录）**：iOS 现在在 `finishEntriesUpdate` 里 `await Task.detached { buildSearchIndex }`（构建完成才返回）。改用 `catalog.rebuildIndexDerived` 后，searchIndex 由 Catalog 的 **deferred fire-and-forget**（scheduleDeferredDerivedRebuild，off-main + generation guard + DispatchQueue.main.async）填充——`rebuildIndexDerived` 返回时 `catalog.searchIndex` 仍为旧值/空，约数百 ms 后就绪。影响：entries 更新后极短窗口内搜索返回旧/空结果。**这与 iOS warm-launch 现状一致**（warm launch 本就先 `.ready` 再后台建索引），且后台 sync 静默、搜索非阻塞——可接受。在 PR body + 代码注释记录。
3. **relationGraph 在 iOS 建而不显示**：`rebuildIndexDerived` 的 deferred 段同时建 relationGraph（off-main，~100-200ms）。iOS 暂不显示关联面板，属轻微浪费——但 off-main 不阻塞 UI，且使 iOS 将来加关联面板零新代码。接受（决策记录）。
4. **iOS 专属胶水不动**：决策不碰 VaultBookmark / ICloudMaterializer / materializeMarkdown / SetupView 选取 / phase·progress·statusLabel / containerDBPath。它们无 Mac 对应物。
5. **bookContext 保持 iOS 按需直调**：DocScreen 直接 `bookContext(for:in:model.entries)`（MarpleKit 自由函数，已共享）——不强行改走 catalog.openBook（iOS 按需模式更省，且已无分叉）。不在本期范围。
6. **Mac 侧零改动**：SessionResolver 是新增（Mac 不读自己的 session，故今天只 iOS 用，但住 MarpleKit 以"可共享 + 让 iOS 壳更瘦"）；catalog.refresh/rebuildIndexDerived Mac 已在用。PR4 几乎纯 iOS + 一个新 MarpleKit 文件。Mac 回归面小。
7. **行为零变化**（除决策 2 记录项）：各步逐字保运算，iOS 单测 + 构建作钉。

## File Structure

```
apple/Sources/MarpleKit/Session/SessionResolver.swift   ← 新：解析 SessionSnapshot → Identifiable 森林
apple/Tests/MarpleKitTests/SessionResolverTests.swift   ← 新
apple/ios/MarpleiOS/App/ReaderModel.swift               ← 改：用 SessionResolver / catalog.searchIndex / catalog.refresh；删 searchIndex 字段 + refreshing 布尔 + 本地 MacTabNode/MacSpaceTabs（移走）
apple/ios/MarpleiOS/UI/SidebarScreen.swift              ← 改：引用 MarpleKit 的解析类型（名字若变则同步）
```

iOS 专属、保持不动：`Vault/VaultBookmark.swift`、`Vault/ICloudMaterializer.swift`、`App/SetupView.swift`、`UI/RootView.swift`、ReaderModel 的 materializeMarkdown/start/containerDBPath/phase/progress。

---

### Task 1: SessionResolver 下沉 MarpleKit（TDD）

把 `ReaderModel.loadSession` 的解析逻辑 + `MacTabNode`/`MacSpaceTabs` 类型搬进 MarpleKit 共享。`Identifiable` 是标准库协议，类型可住 MarpleKit；iOS UI 直接用。

**Files:**
- Create: `apple/Sources/MarpleKit/Session/SessionResolver.swift`
- Test: `apple/Tests/MarpleKitTests/SessionResolverTests.swift`
- Modify: `apple/ios/MarpleiOS/App/ReaderModel.swift`（删本地类型 + loadSession 改调）、`apple/ios/MarpleiOS/UI/SidebarScreen.swift`（类型引用）

- [ ] **Step 1: 写失败测试**

读 `apple/Sources/MarpleKit/Nav/SessionSnapshot.swift`（SessionSnapshot/SessionSpaceSnapshot/SessionNode/OpenDocSnapshot 形状）+ ReaderModel.swift:8-30,220-253（现解析逻辑 = ground truth）。SessionResolverTests：

```swift
import Testing
@testable import MarpleKit

@Suite struct SessionResolverTests {
    private func mk(path: String) -> Entry { /* 照搬 RelationsIndexTests.mk，type 任意 */ }

    @Test func resolvesDocsAndPrunesUnknownPaths() {
        let e = mk(path: "vault/papers/p.md")
        let snap = SessionSnapshot(updatedAtMs: 1000, spaces: [
            SessionSpaceSnapshot(id: UUID(), name: "S", iconName: nil,
                roots: [.doc(OpenDocSnapshot(path: "vault/papers/p.md", title: "P", type: "paper")),
                        .doc(OpenDocSnapshot(path: "vault/gone.md", title: "X", type: "note"))],
                activePath: nil)
        ])
        let spaces = SessionResolver.resolve(snap, entries: [e])
        #expect(spaces.count == 1)
        // 未知 path 被剪，仅剩一个 doc，label 用 snapshot 的 title
        // 断言 spaces[0].roots 仅 1 个 .doc，entry.path == e.path，label == "P"
    }
    @Test func prunesEmptyGroupsAndSpaces() {
        // 一个 group 全是未知 path → group 被剪 → space 森林空 → space 被剪
        let snap = SessionSnapshot(updatedAtMs: 1, spaces: [
            SessionSpaceSnapshot(id: UUID(), name: "S", iconName: nil,
                roots: [.group(name: "G", isCollapsed: false,
                               children: [.doc(OpenDocSnapshot(path: "vault/gone.md", title: "X", type: "note"))])],
                activePath: nil)])
        #expect(SessionResolver.resolve(snap, entries: []).isEmpty)
    }
    @Test func preservesGroupNestingAndCollapse() {
        let e = mk(path: "vault/notes/n.md")
        let snap = SessionSnapshot(updatedAtMs: 1, spaces: [
            SessionSpaceSnapshot(id: UUID(), name: "S", iconName: "star",
                roots: [.group(name: "G", isCollapsed: true,
                               children: [.doc(OpenDocSnapshot(path: "vault/notes/n.md", title: "N", type: "note"))])],
                activePath: "vault/notes/n.md")])
        let spaces = SessionResolver.resolve(snap, entries: [e])
        // 断言 space.iconName=="star"、activePath 保留、roots[0] 是 .group(name:"G", isCollapsed:true) 含 1 子 .doc
    }
    @Test func stableUniqueIDsAcrossNodes() {
        // 每个节点 id 唯一（SwiftUI ForEach 需要）
    }
}
```
（断言细节按 SessionResolver 的真实返回类型补全。）

- [ ] **Step 2: 确认编译失败**

```bash
cd apple && swift test --filter SessionResolverTests 2>&1 | tail -3
```

- [ ] **Step 3: 实现 SessionResolver.swift**

把 ReaderModel 顶部的 `MacTabNode`/`MacSpaceTabs`（重命名为中性名，去掉 "Mac" 前缀:`ResolvedSessionNode`/`ResolvedSessionSpace`）+ `loadSession` 的解析核心（counter ID、byPath 查表、递归剪枝）搬来,公开化:

```swift
import Foundation

/// Mac 发布的 open-tabs.json 解析成可显示森林（QUA-218 PR4 下沉）。
/// 平台无关：把 SessionSnapshot 的 path 引用对当前 entries 解析，剪掉未解析
/// 文档、空 group、空 Space。`Identifiable` 是标准库协议，故住 MarpleKit、
/// iOS SwiftUI 直接用。住 MarpleKit 让 iOS 壳只剩平台胶水（双端互通）。
public enum ResolvedSessionNode: Identifiable {
    case doc(id: String, entry: Entry, label: String)
    case group(id: String, name: String, isCollapsed: Bool, children: [ResolvedSessionNode])
    public var id: String {
        switch self { case .doc(let id,_,_): return id; case .group(let id,_,_,_): return id }
    }
}

public struct ResolvedSessionSpace: Identifiable {
    public let id: UUID
    public let name: String
    public let iconName: String?
    public let roots: [ResolvedSessionNode]
    public let activePath: String?
}

public enum SessionResolver {
    /// 逐字 = 旧 ReaderModel.loadSession 的解析段（byPath 查表 + 递归剪枝 +
    /// counter ID）。文件加载/iCloud 下载留 iOS（IO 平台专属）。
    public static func resolve(_ snapshot: SessionSnapshot, entries: [Entry]) -> [ResolvedSessionSpace] {
        let byPath = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var counter = 0
        func resolveNodes(_ nodes: [SessionNode]) -> [ResolvedSessionNode] {
            nodes.compactMap { node in
                counter += 1
                switch node {
                case .doc(let d):
                    guard let entry = byPath[d.path] else { return nil }
                    return .doc(id: "n\(counter)", entry: entry, label: d.title)
                case .group(let name, let collapsed, let children):
                    let kids = resolveNodes(children)
                    guard !kids.isEmpty else { return nil }
                    return .group(id: "n\(counter)", name: name, isCollapsed: collapsed, children: kids)
                }
            }
        }
        return snapshot.spaces.compactMap { space in
            let roots = resolveNodes(space.roots)
            guard !roots.isEmpty else { return nil }
            return ResolvedSessionSpace(id: space.id, name: space.name,
                                        iconName: space.iconName, roots: roots,
                                        activePath: space.activePath)
        }
    }
}
```
注意 SessionNode 的关联值形状以 SessionSnapshot.swift 真实定义为准（`.doc(OpenDocSnapshot)` vs `.doc(let d)` 解构）。

- [ ] **Step 4: ReaderModel 改调**

删 ReaderModel 顶部 `MacTabNode`/`MacSpaceTabs`（约 8-30 行）。`openOnMacSpaces` 类型改 `[ResolvedSessionSpace]`。`loadSession` 的解析段（230-252）替换为 `openOnMacSpaces = SessionResolver.resolve(snap, entries: entries)`，文件加载 + iCloud 下载 + `openTabsUpdatedAt` 设置（221-229）保留。SidebarScreen 里 `MacSpaceTabs`/`MacTabNode` → `ResolvedSessionSpace`/`ResolvedSessionNode`（或在 ReaderModel 顶 `typealias MacSpaceTabs = ResolvedSessionSpace` 减少 UI 改动——择优，报告选择）。

- [ ] **Step 5: 测试 + iOS 构建 + Commit**

```bash
cd apple && swift test --filter SessionResolverTests 2>&1 | tail -3
cd apple && swift test 2>&1 | tail -3        # macOS 全量不回归（900+）
cd apple/ios && xcodegen generate && xcodebuild build -project MarpleiOS.xcodeproj -scheme MarpleiOS -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/marple-ios-dd CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
git add -A apple/Sources apple/Tests apple/ios
git commit -m "refactor(session): SessionResolver into MarpleKit; iOS reuses shared resolution (QUA-218)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: iOS ReaderModel 驱动 Catalog 的 searchIndex

iOS 持 `Catalog`，entries 变动调 `catalog.rebuildIndexDerived`，搜索读 `catalog.searchIndex`。删手卷 `searchIndex` 字段。

**Files:** Modify `apple/ios/MarpleiOS/App/ReaderModel.swift`。

- [ ] **Step 1: 持 Catalog + 删手卷字段**

ReaderModel 加 `let catalog = Catalog()`。删 `private var searchIndex: SearchIndex = .empty`（49 行）。

- [ ] **Step 2: finishEntriesUpdate 改调 catalog**

`finishEntriesUpdate`（207-212）的 `self.searchIndex = await Task.detached { buildSearchIndex(newEntries) }.value` 替换为 `catalog.rebuildIndexDerived(entries: newEntries, savedViews: [])`（同步返回；searchIndex 由 Catalog deferred 段填充——决策 2 时序）。`loadSession` 调用保留。**注意**：rebuildIndexDerived 是同步的（deferred 段 fire-and-forget），故 `finishEntriesUpdate` 不再需要 await 构建——但其仍 `async`（loadSession 是 async），保持签名。

- [ ] **Step 3: search 改读 catalog.searchIndex**

`search(_:)`（188-196）的 `let index = searchIndex` → `let index = catalog.searchIndex`，`searchDocuments(index, trimmed)` 不变。

- [ ] **Step 4: iOS 构建 + 测试 + Commit**

```bash
cd apple/ios && xcodegen generate && xcodebuild build -project MarpleiOS.xcodeproj -scheme MarpleiOS -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/marple-ios-dd CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild test -project MarpleiOS.xcodeproj -scheme MarpleiOS -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/marple-ios-dd CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
cd .. && swift test 2>&1 | tail -3   # macOS 不回归
git add -A apple/ios
git commit -m "refactor(ios): ReaderModel drives Catalog for searchIndex (QUA-218)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: iOS 刷新走 catalog.refresh（统一单飞）

iOS 的 reconcile→index→derive 包进 `catalog.refresh(body:)`，复用 RefreshAuthority 合流+generation，删 `refreshing` 布尔。materializeMarkdown（iCloud）留在 body 内 iOS 专属段。

**Files:** Modify `apple/ios/MarpleiOS/App/ReaderModel.swift`。

- [ ] **Step 1: backgroundSync 改用 catalog.refresh**

读现 `backgroundSync`（162-178）。改为:
```swift
    private func backgroundSync(root: String, dbPath: String) async {
        await catalog.refresh { [weak self] myPass in
            guard let self else { return }
            await self.materializeMarkdown(under: root, report: false)   // iOS 专属，留
            do {
                try await Task.detached(priority: .utility) {
                    _ = try VaultIndexer(workspaceRoot: root, indexDBPath: dbPath).reconcile()
                }.value
                if self.catalog.isStale(myPass) { return }               // 新 pass 抢先→丢弃
                if let c = self.client { await self.updateEntries(try await c.index()) }
            } catch {
                print("[marple] background sync failed (keeping last entries): \(error)")
            }
        }
    }
```
删 `private var refreshing = false`（61 行）+ 其 guard/defer（166-168）——`catalog.refresh` 的 tryBegin 合流取代它（且更强:1 主 + 1 trailing rerun，而非简单丢弃）。**核对语义**:旧 `refreshing` 是"忙就丢"；`catalog.refresh` 是"忙就置 trailing rerun、跑完再补一轮"——对 iOS 前台 sync 是等价或更优（不丢最后一次信号）。报告此差异（属改进，无害）。

- [ ] **Step 2: 确认其它 loadIndex/index 直调点**

iOS 的 cold start（start 的 135-149）首次 index 是独立的（非 backgroundSync）；保持不变（它本就不经 `refreshing`）。grep ReaderModel 确认 `refreshing` 无残留引用。

- [ ] **Step 3: iOS 构建 + 测试 + Commit**

```bash
cd apple/ios && xcodegen generate && xcodebuild build -project MarpleiOS.xcodeproj -scheme MarpleiOS -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/marple-ios-dd CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild test -project MarpleiOS.xcodeproj -scheme MarpleiOS -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/marple-ios-dd CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
git add -A apple/ios
git commit -m "refactor(ios): backgroundSync via catalog.refresh single-flight; drop refreshing bool (QUA-218)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: 终验 + PR

- [ ] **Step 1: macOS 不回归 + 警告基线**

```bash
cd apple && swift build 2>&1 | grep "warning:" | sort | uniq -c
cd apple && swift test 2>&1 | tail -3
```
Mac 全绿、警告基线（PR4 几乎不碰 Mac，应零回归）。

- [ ] **Step 2: iOS 构建 + 测试**

```bash
cd apple/ios && xcodegen generate
xcodebuild build -project MarpleiOS.xcodeproj -scheme MarpleiOS -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/marple-ios-dd CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild test -project MarpleiOS.xcodeproj -scheme MarpleiOS -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/marple-ios-dd CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
`BUILD SUCCEEDED` + iOS 测试全绿（TableRenderingTests/RenderCrashTests/IOSVaultClientTests + 新 SessionResolverTests 经 MarpleKit）。

- [ ] **Step 3: ReaderModel 瘦身核对**

确认 iOS 壳剩下的 iOS-only 代码只有真边界胶水（VaultBookmark/ICloudMaterializer/materializeMarkdown/SetupView/phase·progress/containerDBPath）。`grep -n "buildSearchIndex\|searchDocuments\|MacTabNode\|MacSpaceTabs\|refreshing" apple/ios/MarpleiOS` → searchIndex/session 平行逻辑已无（bookContext 按需直调保留，决策 5）。

- [ ] **Step 4: push + PR（含 TestFlight 验证说明）**

```bash
git push -u origin qua-218-pr4
gh pr create --title "refactor(ios): L4 验收 — iOS 接 Catalog，双端最大化互通 (QUA-218, PR4)" --body "<见下>"
```
PR body 要点：三步收 B 类（SessionResolver 下沉 / searchIndex 走 Catalog / 刷新走 catalog.refresh）；iOS 壳现只剩真平台胶水；决策 2 的 searchIndex 时序变更（更新后短暂空窗，与 warm-launch 现状一致）+ 决策 3 的 relationGraph 轻微浪费（off-main，换关联面板未来零成本）+ 决策 1 的"忙就补一轮"优于旧"忙就丢"；Mac 零改动、零回归；iOS 构建+测试绿。

- [ ] **Step 5: （可选，交用户）TestFlight 真机验收**

iOS 行为变更（搜索/侧栏/刷新）最好真机抽查。若用户要：bump `apple/ios/project.yml` 的 `CURRENT_PROJECT_VERSION`，`cd apple/ios && ./release.sh`（CLAUDE.md §6），TestFlight 处理 ~10-30min。清单：① 文库浏览/搜索（输入查得到、结果排序合理）；② 侧栏「Mac 上打开的」Space/分组/嵌套/别名/「同步于…」footer 正常（SessionResolver 验证）；③ 开文档渲染 + 本书导航正常；④ 前后台切换刷新不卡、不丢更新（catalog.refresh 单飞）。

---

## Self-Review 记录

- **Spec 覆盖**：§6.4「PR4 iOS 接 Catalog 删手写复制品 = 真平台无关验收」→ Task 1-3；§4「iOS ReaderModel 瘦身接 Catalog」→ 达成（B 类全收，剩真胶水）。
- **Placeholder**：测试断言以"按真实返回类型补全"指明；SessionNode 解构以真定义为准。
- **类型一致**：`SessionResolver.resolve(_:entries:)`、`ResolvedSessionNode`/`ResolvedSessionSpace`、`catalog.rebuildIndexDerived(entries:savedViews:)`、`catalog.refresh`/`isStale` 各处一致。
- **行为差异账**：仅决策 2（searchIndex 时序，记录）+ 决策 3（relationGraph 浪费，记录）+ Task 3 的"忙就补一轮 vs 忙就丢"（改进）。其余逐字。
- **回归面**：Mac 仅因新增 SessionResolver 文件而编译；catalog API 未改。iOS 是主改动面，xcodebuild build+test 作钉。
