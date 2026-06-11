# QUA-218 PR3a — L2 收口：Catalog 立起 + 派生状态收归 + 防竞态 3→1

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** 把 AppModel 散落的派生状态与重算收归到一个新 `Catalog`（MarpleKit），并把 vault-变更管线上的三套防竞态机制（RefreshGate + loadIndexGeneration + derivedGeneration）统一为 Catalog 一套 generation/单飞；AppModel 计算属性门面转发，视图零改动，行为零变化。

**Architecture:** `Catalog` 是 `@MainActor @Observable final class`（MarpleKit/Catalog/Catalog.swift），持有全部派生缓存与重算方法。派生输入（entries、pane/filter/sort、openPath/openBody、savedViews）由 AppModel 以方法参数喂入——Catalog 尽量是 `f(vault, 选择)`。AppModel 保留 `entries`/index reader/loadIndex body 与瞬时 UI 状态，并为每个被搬走的属性提供 `var X { catalog.X }` 计算转发（SwiftUI Observation 会穿透嵌套 @Observable 追踪）。防竞态统一只针对 vault-变更管线（3→1）；`searchMatchQuery`（搜索防抖轴）与 `recomputeTask`（filter/sort 防抖轴）是无关轴，保留独立。

**Tech Stack:** Swift 6 / Swift Observation（`@Observable`）/ swift-testing。`apple/.build` 是符号链接，**永不删**。`swift test` 收尾可能 SIGPIPE exit 13（QUA-208 已知），看汇总行判成败。基线警告：VectorStore cblas_sgemv ×1、CollectionGridVariant MainActor ×2、Tests Fixtures unhandled-file ×1——不得新增。

---

## 计划级决策（已定，执行者不再判断）

1. **统一范围 = 诚实 2→1（用户已批准，修正自初版 3→1）**：只折叠**纯刷新管线**的两套——`RefreshAuthority`（链准入/合流，**QUA-198 OOM 承重墙**）+ `loadIndexGeneration`（loadIndex 管线陈旧丢弃，且 loadIndex 只在 refresh 单飞内跑）——为 Catalog 一套**单飞 + per-pass `pass` generation**（`catalog.refresh`）。`derivedGeneration` **保持独立**（已在 Task 3 搬进 Catalog，不并入 `pass`）：因为 `scheduleDeferredDerivedRebuild` 除 loadIndex 外，还被**乐观单条编辑**（`applyPatch`/`setRating`/`setAuthor`/`importImage`/`moveToTrash`）在 refresh 之外直接触发——若折进只在 refresh 时 bump 的 `pass`，连续两次乐观编辑共享同一 pass，第一次后台 `RelationGraph.build` 慢完成会覆盖第二次新结果（**正确性回归**）。与 `searchMatchQuery`/`recomputeTask`/`matchTask` 同理：**有刷新管线之外的独立触发轴的，一律保持独立**，不得并进 `pass`。
2. **OOM 安全承重点**：generation 检查只防"陈旧结果覆盖",**不 bound 并发**——陈旧 task 照样跑到挂起点。因此统一权威必须**保留 RefreshAuthority 的合流单飞**（"1 个在跑 + 1 个待重跑",不排队),把 `loadIndexGeneration` 并进"当前 pass 的 generation"。**绝不可**用 generation 检查替掉合流。IndexDatabase 的 cache-write 单飞（QUA-198 下层，MarpleKit/Vault）原样不动。
3. **entries 与 index 管线暂留 AppModel（过渡）**：本期 Catalog 持有**派生状态**与**统一权威**;`entries`、index reader（`client`）、`reconcile`/`loadIndex` 的 body 暂留 AppModel,作为统一单飞运行的闭包喂入。完整把 entries+loadIndex 搬进 `Catalog.refresh()` 留待后续 PR（spec 的终态,本期不做,以控制 blast radius)。这仍满足 spec「收拢为一套 generation/单飞」——统一的是 generation/flight,orchestration body 过渡期留壳。
4. **VaultChangeSource 协议**：本期引入 `protocol VaultChangeSource`(watcher/CLI/boot 三个触发点共同契约),Mac 的 `VaultWatcher` 实现它,三处触发改为走 `catalog.refresh(body:)`。FSEvents 0.4s 防抖常量（VaultWatcher Coalescer）**逐字不动**。
5. **门面转发**：AppModel 为每个搬走的属性加 `private(set)`-语义的计算 getter `var X: T { catalog.X }`(只读属性)或转发方法。视图继续写 `model.X`,**零改动**。先用 Task 1 验证 @Observable 嵌套转发触发重渲染,再继续。
6. **Catalog 不持有 AppModel 强引用**：派生输入走方法参数；若个别重算确需回读壳状态,用 `weak`/协议,不建强引用环。
7. **行为零变化**：每个搬移任务,把现有函数体**逐行搬运**(只改 `self.X` 的归属与输入来源),不重写逻辑;现有测试 + 新增 Catalog 单测作等价钉。

## File Structure

```
apple/Sources/MarpleKit/Catalog/Catalog.swift            ← 新：@Observable owner + 重算方法 + 统一权威
apple/Sources/MarpleKit/Catalog/RefreshAuthority.swift   ← 新：单飞+generation（RefreshGate 的迁入+泛化）
apple/Sources/MarpleKit/Vault/VaultChangeSource.swift     ← 新：协议（watcher/CLI/boot 契约）
apple/Sources/MarpleKit/Vault/VaultWatcher.swift          ← 改：conform VaultChangeSource（0.4s 不动）
apple/Sources/Marple/App/AppModel.swift                   ← 改：持 catalog；门面转发；删搬走的存储/逻辑
apple/Sources/Marple/App/RefreshGate.swift                ← 删（逻辑迁入 RefreshAuthority）
apple/Sources/Marple/App/MarpleApp.swift                  ← 改：boot/watcher 走 catalog.refresh
apple/Sources/Marple/CLI/AppModel+CLI.swift               ← 改：cliRefreshIndex 走 catalog.refresh
apple/Tests/MarpleKitTests/CatalogTests.swift             ← 新
apple/Tests/MarpleKitTests/RefreshAuthorityTests.swift    ← 新
```

被搬走后 AppModel 仍持有的输入/瞬时态：`entries`、`client`、`indexer`、`reconcile`/`loadIndex` body、`openPath`/`openBody`/`openBlocks`、`searchText`/`pane`/`filters`/`sort`、`set*`/`applyPatch`（PR3b 搬）、所有持久化（PR3b 搬）。

---

### Task 1: Catalog 骨架 + 门面转发验证（先证嵌套观测）

**目的**：在搬任何逻辑前,先证明 `@Observable Catalog` 的属性经 AppModel 计算 getter 转发后,视图读 `model.X` 仍能正确重渲染。拿一个低风险属性 `themeIndex` 试。

**Files:**
- Create: `apple/Sources/MarpleKit/Catalog/Catalog.swift`
- Modify: `apple/Sources/Marple/App/AppModel.swift`
- Test: `apple/Tests/MarpleKitTests/CatalogTests.swift`

- [ ] **Step 1: 建 Catalog 骨架**

```swift
import Foundation

/// L2 编目层的派生状态 owner（QUA-218 PR3a）。图书馆目录隐喻：从馆藏（vault）
/// 派生、可随时重编、多路检索、带交叉引用。本期持有派生缓存 + vault-变更管线
/// 的统一 generation/单飞权威；entries 与 index 管线过渡期仍在 AppModel。
@MainActor
@Observable
public final class Catalog {
    // 索引派生（entries 变即重算）
    public internal(set) var themeIndex: [ThemeCount] = []

    public init() {}
}
```
（其余属性后续任务逐个迁入。`ThemeCount` 已在 MarpleKit，确认可见。）

- [ ] **Step 2: AppModel 持有 catalog + themeIndex 转发**

在 AppModel 属性区：
```swift
    let catalog = Catalog()
```
删除 AppModel 原 `private(set) var themeIndex: [ThemeCount] = []`,替换为转发 getter：
```swift
    var themeIndex: [ThemeCount] { catalog.themeIndex }
```
`rebuildIndexDerived()` 中原 `themeIndex = themeCounts(entries)` 改为 `catalog.themeIndex = themeCounts(entries)`。

- [ ] **Step 3: 验证测试**

CatalogTests：
```swift
import Testing
@testable import MarpleKit

@MainActor @Suite struct CatalogTests {
    @Test func themeIndexStoresAndReads() {
        let c = Catalog()
        c.themeIndex = [ThemeCount(theme: "x", count: 3)]   // 按 ThemeCount 真实 init 调整
        #expect(c.themeIndex.map(\.theme) == ["x"])
    }
}
```
（ThemeCount 的真实初始化器以源码为准。）

- [ ] **Step 4: 全量测试 + GUI 烟雾**

```bash
cd apple && swift test 2>&1 | tail -3
```
全绿（基线 +1）。**门面转发的重渲染由 ThemesView 在最终 GUI 清单验证**（Task 9）——此处先确保编译/单测过、ThemesView 读 `model.themeIndex` 仍编译。

- [ ] **Step 5: Commit**

```bash
git add apple/Sources/MarpleKit/Catalog/Catalog.swift apple/Sources/Marple/App/AppModel.swift apple/Tests/MarpleKitTests/CatalogTests.swift
git commit -m "feat(catalog): Catalog @Observable skeleton + themeIndex facade forward (QUA-218)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: 立即索引派生迁入（counts / savedViewCounts / topicMembership）

**Files:** Modify `Catalog.swift`, `AppModel.swift`; extend `CatalogTests.swift`.

把 `rebuildIndexDerived()` 的立即部分迁入 Catalog。逐行搬运,不改逻辑。

- [ ] **Step 1: Catalog 加属性 + 方法**

Catalog 加：
```swift
    public internal(set) var counts: [EntryType: Int] = [:]
    public internal(set) var savedViewCounts: [UUID: Int] = [:]
    public internal(set) var topicMembership: TopicMembership = TopicMembership()
```
迁入方法（把 AppModel 现 `rebuildIndexDerived` 立即段、`recomputeSavedViewCounts` 的**函数体逐行搬来**,签名改为吃参数；`topicBrowseSubset`/`browseUniverse`/`themeCounts`/`buildTopicMembership` 若是 AppModel 私有,判断：纯函数则一并迁入 Catalog 或提为 MarpleKit 自由函数;依赖壳状态的留壳并经参数传入）：
```swift
    /// entries 变更后的立即派生（counts/themeIndex/topicMembership/savedViewCounts）。
    /// 逐字 = 旧 AppModel.rebuildIndexDerived 立即段 + recomputeSavedViewCounts。
    /// 注意：deferred 段（relationGraph/searchIndex）在 Task 3 迁入。
    public func rebuildIndexDerived(entries: [Entry], savedViews: [SavedView]) {
        var c: [EntryType: Int] = [:]
        for e in entries { c[e.type, default: 0] += 1 }
        // …topic-bucket 折叠等：照搬旧 L499-503
        counts = c
        recomputeSavedViewCounts(entries: entries, savedViews: savedViews)
        themeIndex = themeCounts(entries)
        topicMembership = buildTopicMembership(entries)
        // scheduleDeferredDerivedRebuild() —— Task 3 接上
    }
```
`SavedView` 真实类型以源码为准（AppModel L513-524、savedViews L157）。

- [ ] **Step 2: AppModel 转发 + 调用改写**

删 AppModel 的 `counts`/`savedViewCounts`/`topicMembership` 存储,加转发 getter。AppModel 原 `rebuildIndexDerived()` 改为：
```swift
    private func rebuildIndexDerived() {
        catalog.rebuildIndexDerived(entries: entries, savedViews: savedViews)
        scheduleDeferredDerivedRebuild()   // Task 3 前暂留壳
    }
```
`savedViews.didSet`（L157）原调 `recomputeSavedViewCounts()` 改为 `catalog.recomputeSavedViewCounts(entries: entries, savedViews: savedViews)`。

- [ ] **Step 3: 等价测试**

CatalogTests 加 counts/topicMembership 的小样本断言（mk 工厂照搬 RelationsIndexTests）。

- [ ] **Step 4: 全量 + Commit**

```bash
cd apple && swift test 2>&1 | tail -3
git add -A apple/Sources apple/Tests && git commit -m "feat(catalog): move immediate index-derived (counts/savedViews/topicMembership) into Catalog (QUA-218)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: 后台派生迁入（relationGraph / searchIndex + derivedGeneration）

**Files:** Modify `Catalog.swift`, `AppModel.swift`; extend tests.

`scheduleDeferredDerivedRebuild` + `derivedGeneration` 整体迁入 Catalog（derivedGeneration 是 3→1 的一员,本任务先随派生搬入由 Catalog 持有,Task 7 再并进统一 generation）。

- [ ] **Step 1: Catalog 加 deferred 派生**

```swift
    public internal(set) var relationGraph: RelationGraph = .empty
    public internal(set) var searchIndex: SearchIndex = .empty
    private var deferredDerivedTask: Task<Void, Never>?
    private var derivedGeneration: Int = 0
```
迁入 `scheduleDeferredDerivedRebuild`（**逐行搬** AppModel L533-560：cancel→bump→snapshot→detached(.utility) build RelationGraph+searchIndex→DispatchQueue.main.async + generation guard→赋值）。其中 `recomputeOpenDerived()` 的回调（旧 L557）此刻 Catalog 还没有它——本任务先回调一个注入的闭包 `onDerivedReady: (() -> Void)?`（AppModel 设为 `{ [weak self] in self?.recomputeOpenDerived() }`),Task 5 把 recomputeOpenDerived 也迁入后改为直接调用。`buildSearchIndex` 若是 AppModel 自由/私有函数,迁入或提 MarpleKit。

`rebuildIndexDerived` 末尾接上 `scheduleDeferredDerivedRebuild(entries:)`。

- [ ] **Step 2: AppModel 转发**

删 relationGraph/searchIndex 存储 + derivedGeneration/deferredDerivedTask,加转发 getter。AppModel.rebuildIndexDerived 简化为仅 `catalog.rebuildIndexDerived(entries:savedViews:)`（deferred 现由 Catalog 内部接上）。设 `catalog.onDerivedReady`。

- [ ] **Step 3: 等价测试 + 全量 + Commit**

```bash
cd apple && swift test 2>&1 | tail -3
git add -A apple/Sources apple/Tests && git commit -m "feat(catalog): move deferred derive (relationGraph/searchIndex) + derivedGeneration into Catalog (QUA-218)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: visibleEntries + 搜索匹配缓存迁入（独立轴保留）

**Files:** Modify `Catalog.swift`, `AppModel.swift`; extend tests.

迁入 `recomputeVisible`（+ `recomputeTask`,filter/sort 防抖轴）、`searchMatches`/`searchMatchQuery`/`matchExpanded` 与 `computeSearchMatches`（+ `searchTask` 搜索防抖轴）。**这两套取消/版本令牌按决策 1 保持独立,不并进统一 generation。**

- [ ] **Step 1: Catalog 加属性 + 方法**

```swift
    public internal(set) var visibleEntries: [Entry] = []
    public internal(set) var searchMatches: [String: BodyMatches] = [:]
    public internal(set) var searchMatchQuery: String = ""
    public var matchExpanded: Set<String> = []
    private var recomputeTask: Task<Void, Never>?    // filter/sort 防抖轴（独立）
```
`searchTask` 留在 AppModel 还是迁入 Catalog？——`recomputeVisible`/`computeSearchMatches` 读 `searchText`/`searchHits`/`pane`/`activeFilterClauses`/`activeSortClauses`（壳 UI 态）。方案：迁入方法体,inputs 经参数；`recomputeVisible(searchHits:pane:filters:match:sort:browsing:)`、`computeSearchMatches(query:paths:liveQuery:)`（liveQuery 用于发布前的 `searchText == query` 守卫——把"当前 query 是否仍是这个"判断以闭包/值传入,保持旧 L1039 守卫语义）。`searchText` 仍是壳的输入,Catalog 不持有它。

- [ ] **Step 2: 逐行搬运 + AppModel 转发**

把旧 `recomputeVisible`(L591-610)、`computeSearchMatches`(L1023-1043)、`clearSearchMatches`、`toggleMatchExpanded` 体逐行搬入,`self.X` 归 Catalog,输入改参数。AppModel 调用点改 `catalog.recomputeVisible(...)` 等,加全部转发 getter。注意 `openMatchedLine`（L1054）读 `searchMatchQuery` → `catalog.searchMatchQuery`。

- [ ] **Step 3: 等价测试 + 全量 + Commit**

搜索/可见性多为集成行为；以现有 AppModel/list 测试为等价钉,CatalogTests 补可断言的纯片段。
```bash
cd apple && swift test 2>&1 | tail -3
git add -A apple/Sources apple/Tests && git commit -m "feat(catalog): move visibleEntries + search-match caches into Catalog (independent debounce axes kept) (QUA-218)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: 开档派生缓存迁入（recomputeOpenDerived）

**Files:** Modify `Catalog.swift`, `AppModel.swift`; extend tests.

迁入 `openEntry`/`openOutline`/`openStats`/`openRelations`/`openBook`/`openTopic` 与 `recomputeOpenDerived`。`openBody`/`openBlocks`/`openPath` 留壳（loadDoc 设的文本/导航态）,作输入传入。

- [ ] **Step 1: Catalog 加开档缓存 + 方法**

```swift
    public internal(set) var openEntry: Entry?
    public internal(set) var openOutline: [OutlineItem] = []
    public internal(set) var openStats: DocStats?
    public internal(set) var openRelations: Relations?
    public internal(set) var openBook: BookContext?
    public internal(set) var openTopic: TopicContext?

    /// 逐字 = 旧 AppModel.recomputeOpenDerived（L562-583）。openPath/openBody 由壳传入。
    public func recomputeOpenDerived(openPath: String?, openBody: String, entries: [Entry]) {
        guard let openPath, let e = entries.first(where: { $0.path == openPath }) else {
            openEntry = nil; openRelations = nil; openBook = nil; openTopic = nil
            // …旧 L578-581 的清空集合：照搬
            return
        }
        openEntry = e
        // …outline/stats/relations(graph: relationGraph, topicMembership: topicMembership)/bookContext/topicContext：逐行搬旧 L570-577
    }
```
relations() 用 `self.relationGraph`/`self.topicMembership`（已在 Catalog）。`Wikilink.preprocessForRendering`/`outline`/`computeDocStats` 等照旧调用（MarpleKit 内）。

- [ ] **Step 2: AppModel 转发 + onDerivedReady 直连**

删开档缓存存储,加转发 getter。loadDoc(L1108)/applyPatch(L1799)/reloadOpen(L1129) 的 `recomputeOpenDerived()` 调用改 `catalog.recomputeOpenDerived(openPath: openPath, openBody: openBody, entries: entries)`。Task 3 注入的 `catalog.onDerivedReady` 改为 Catalog 内部直接 `recomputeOpenDerived(...)`——但它需 openPath/openBody（壳态）：保留 `onDerivedReady` 闭包注入（AppModel 提供 `{ [weak self] in guard let self else {return}; self.catalog.recomputeOpenDerived(openPath: self.openPath, openBody: self.openBody, entries: self.entries) }`）。

- [ ] **Step 3: 等价测试 + 全量 + Commit**

CatalogTests 加 open-doc 派生小样本（chapter→openBook、topic→openTopic、author works 经 relationGraph）。
```bash
cd apple && swift test 2>&1 | tail -3
git add -A apple/Sources apple/Tests && git commit -m "feat(catalog): move open-doc derived caches into Catalog (QUA-218)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: RefreshAuthority — 单飞 + generation（RefreshGate 迁入泛化，TDD）

**目的**：把 `RefreshGate` 迁入 MarpleKit 成 `RefreshAuthority`,并准备承载统一 generation。**本任务先做行为等价迁移 + 单测**,Task 7 再把 loadIndexGeneration/derivedGeneration 并入。

**Files:**
- Create: `apple/Sources/MarpleKit/Catalog/RefreshAuthority.swift`
- Test: `apple/Tests/MarpleKitTests/RefreshAuthorityTests.swift`
- Modify: `AppModel.swift`/`MarpleApp.swift`/`AppModel+CLI.swift`（指向新类型）；Delete `apple/Sources/Marple/App/RefreshGate.swift`

- [ ] **Step 1: 读旧 RefreshGate 全文,写等价单测**

RefreshAuthorityTests 钉死合流语义（用 actor + 计数验证）：
- `tryBegin` 在 busy 时返回 false 且置 rerun；
- `finishOrRerun` 在 rerun 置位时回 true 并清位、否则 false 并释放；
- `beginOrJoin` 在 busy 时挂起、待一次 trailing rerun 完成后 resume；
- "N 个并发信号 → body 至多跑 2 次（1 主 + 1 trailing）"的合流不变量（OOM 承重点的可测代理）。

- [ ] **Step 2: 迁入逻辑（逐字）**

`RefreshAuthority` = 旧 `RefreshGate` 的 actor 体逐字搬入 MarpleKit（同 API：tryBegin/beginOrJoin/finishOrRerun + waiters）。命名可保留 RefreshGate 或更名 RefreshAuthority——更名则全调用点同步。

- [ ] **Step 3: 三处调用点指向新类型 + 删旧文件**

`AppModel.refreshGate`、`MarpleApp` watcher 闭包、`AppModel+CLI.cliRefreshIndex` 改用 `RefreshAuthority`。删 `RefreshGate.swift`。`grep -rn "RefreshGate" apple/` 仅余注释/历史。

- [ ] **Step 4: 测试 + Commit**

```bash
cd apple && swift test --filter RefreshAuthorityTests 2>&1 | tail -3
cd apple && swift test 2>&1 | tail -3
git add -A apple/Sources apple/Tests && git commit -m "refactor(catalog): RefreshGate -> MarpleKit RefreshAuthority (behavior-identical) (QUA-218)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: 2→1 统一 + VaultChangeSource（承重任务，最仔细）

**目的**：把 `loadIndexGeneration` 并入 Catalog 的**一套 per-pass generation**,由 `RefreshAuthority` 的单飞驱动,经 `catalog.refresh(body:)` 暴露唯一入口;watcher/CLI/boot 走 `VaultChangeSource` 契约。**合流单飞结构保留(OOM 安全),generation 只增统一性。** `derivedGeneration` **保持独立、不并入 `pass`**（决策 1：它有乐观单条编辑这条刷新管线之外的独立触发轴，折叠会引入派生覆盖竞态）。

**Files:** `Catalog.swift`, `RefreshAuthority.swift`, new `VaultChangeSource.swift`, `VaultWatcher.swift`, `AppModel.swift`, `MarpleApp.swift`, `AppModel+CLI.swift`; tests.

- [ ] **Step 1: Catalog 暴露统一权威**

```swift
    private let authority = RefreshAuthority()
    public private(set) var pass: Int = 0          // 唯一 per-pass generation
    public func currentPass() -> Int { pass }

    /// 唯一刷新入口。合流单飞（保留 OOM bound）+ 每 pass bump 一次 generation。
    /// body 是壳提供的 reconcile→loadIndex 闭包（过渡期 orchestration 留壳）。
    /// body 内部用 `isStale(myPass)` 在每个挂起点后自检,陈旧即丢弃发布。
    public func refresh(_ body: @escaping (_ myPass: Int) async -> Void) async {
        guard await authority.tryBegin() else { return }
        repeat {
            pass &+= 1
            let myPass = pass
            await body(myPass)
        } while await authority.finishOrRerun()
    }
    public func refreshJoining(_ body: @escaping (_ myPass: Int) async -> Void) async {
        if await authority.beginOrJoin() {
            repeat { pass &+= 1; let p = pass; await body(p) } while await authority.finishOrRerun()
        }
    }
    public func isStale(_ myPass: Int) -> Bool { pass != myPass }
```
**derivedGeneration 不动**（决策 1 修正）：`scheduleDeferredDerivedRebuild` 仍用 Catalog 自己的 `derivedGeneration`（Task 3 已搬入），**不**改用 `pass`。原因：它被乐观单条编辑在 refresh 之外触发，折进只在 refresh 时 bump 的 `pass` 会让连续两次编辑共享同一 pass、第一次慢派生覆盖第二次（正确性回归）。`pass` 只服务 loadIndex 管线陈旧丢弃。

- [ ] **Step 2: AppModel loadIndex 改吃 myPass**

`loadIndex` 去掉自有 `loadIndexGeneration`,签名 `loadIndex(pass myPass: Int)`,三个挂起点后的 `loadIndexGeneration == generation` 守卫改 `!catalog.isStale(myPass)`（逐行,语义同）。`refreshChain` body 改 `{ myPass in await reconcile…; await loadIndex(pass: myPass); await reloadOpen() }`。

- [ ] **Step 3: 三处触发走 catalog.refresh + VaultChangeSource**

新 `VaultChangeSource.swift`：
```swift
public protocol VaultChangeSource: AnyObject {
    /// 实现方在 vault 变化时调用注入的 onChange；onChange 内部走 catalog.refresh。
    func start(onChange: @escaping @MainActor () -> Void)
    func stop()
}
```
`VaultWatcher` conform（**0.4s Coalescer 不动**,只把"调 refreshChain"改成调注入的 onChange）。MarpleApp watcher 闭包 → `await catalog.refresh(refreshBody)`;boot 同;`AppModel+CLI.cliRefreshIndex` → `await catalog.refreshJoining(refreshBody)`。删 AppModel 的 `refreshGate` 持有（移交 Catalog.authority）。

- [ ] **Step 4: 统一不变量测试**

RefreshAuthorityTests/CatalogTests 加：并发 refresh 触发下 body 至多跑 2 次（合流保留）；陈旧 pass 的 body 自检 isStale 为真;join 路径会跑到一次新 pass。**OOM 代理断言**：M 个并发 refresh → body 调用次数 ≤ 2（不随 M 增长）。

- [ ] **Step 5: 全量 + Commit**

```bash
cd apple && swift test 2>&1 | tail -3
git add -A apple/Sources apple/Tests && git commit -m "feat(catalog): unify vault-change anti-race 3->1 under Catalog.refresh + VaultChangeSource (QUA-218)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

**若本任务在执行中证明过大或风险失控**：Task 1-6 是自洽可发布的（派生收归 + RefreshGate 迁移,行为等价）。可在此停,把 Task 7 拆为独立 PR3a-ii,先发 PR3a-i。计划允许此回退。

---

### Task 8: AppModel 瘦身核对 + 死代码清理

**Files:** `AppModel.swift`。

- [ ] **Step 1: 核对转发完整**

`grep -n "var .*: .* { catalog\." apple/Sources/Marple/App/AppModel.swift` 列出全部转发；逐一对照视图 reader（counts/themeIndex/topicMembership/visibleEntries/relationGraph/searchIndex/searchMatches/searchMatchQuery/matchExpanded/trashItems/open*）确认无遗漏、无残留旧存储。

- [ ] **Step 2: 删 Task 改动产生的孤儿**

仅删本 PR 改动造成无引用的私有函数/属性（如壳里已空壳的旧 generation 字段）。`swift build 2>&1 | grep -c warning:` 不超基线。

- [ ] **Step 3: 全量 + Commit**

```bash
cd apple && swift test 2>&1 | tail -3
git add -A apple/Sources && git commit -m "refactor(catalog): prune AppModel orphans after Catalog extraction (QUA-218)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 9: 终验 + PR

- [ ] **Step 1: macOS 全量 + 警告基线**

```bash
cd apple && swift build 2>&1 | grep "warning:" | sort | uniq -c
cd apple && swift test 2>&1 | tail -3
```
警告集合 = 基线（cblas_sgemv ×1、CollectionGridVariant ×2、Fixtures unhandled ×1）,无新增。

- [ ] **Step 2: iOS 构建**

```bash
cd apple/ios && xcodegen generate && xcodebuild build -project MarpleiOS.xcodeproj -scheme MarpleiOS -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/marple-ios-dd CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```
`BUILD SUCCEEDED`（iOS 不消费 Catalog 新 API,但共享 MarpleKit 须编译过）。

- [ ] **Step 3: make install + GUI 清单（交用户,含并发压力项）**

```bash
cd apple && make install
```
清单：① 侧栏 counts/themeIndex/saved-view 徽标正常（**门面转发重渲染验证**）；② 打开 paper/章/topic：关联面板、本书、本专题、相似、作者作品如旧；③ 列表 filter/sort/搜索高亮、"再显示 N 个匹配项"展开正常（独立防抖轴未坏）；④ Cmd-K 快速模式排序正常（searchIndex）；⑤ 回收站徽标/列表正常；⑥ **并发压力（OOM 安全）**：在 vault 里快速连续改多个文件 / 跑一次 `marple-cli` 写操作,观察内存不飙升、UI 刷新一次到位、无卡死（3→1 合流验证）；⑦ tab 切换、wikilink 跳转正常。

- [ ] **Step 4: push + PR**

```bash
git push -u origin qua-218-pr3a
gh pr create --title "refactor(catalog): L2 收口 — Catalog owner + anti-race 3→1 (QUA-218, PR3a)" --body "<见下>"
```
PR body 要点：Catalog 立起持全部派生 + 门面转发视图零改动；vault-变更管线三套防竞态 3→1 统一（合流单飞保留=OOM 安全,QUA-198 不回归）;searchMatchQuery/filter-sort 两防抖轴有意保留独立(列出理由);entries+index 管线过渡期留壳(后续 PR 搬);VaultChangeSource 契约引入,0.4s 防抖不动;行为零变化。

---

## Self-Review 记录

- **Spec 覆盖**：§3.4「Catalog 唯一 owner / catalog.refresh / 四套收一套」→ Task 1-7(3→1,第 4 轴有意独立,决策 1 已批准);§3.6「壳里只剩组合根+瞬时态」→ 部分达成(entries/index 管线过渡留壳,决策 3 注明,终态后续 PR);§6.3「视图零改动」→ 门面转发,Task 1 先验证、Task 9 GUI 钉。
- **Placeholder**：函数体迁移以"逐行搬旧 L###"指明,源行号据研究报告;真实类型(SavedView/ThemeCount/BodyMatches/OutlineItem/DocStats)以源码为准已标注。
- **类型一致**：`Catalog`(@MainActor @Observable)、`RefreshAuthority`(actor)、`VaultChangeSource`(protocol)、`catalog.refresh(_:)`/`refreshJoining(_:)`/`isStale(_:)`/`currentPass()`/`pass` 各任务一致。
- **OOM 不变量**：决策 2 + Task 6/7 的合流单飞保留 + Task 7 Step4 的"body ≤2 次"代理断言三处锚定。
- **回退**：Task 1-6 自洽可发布,Task 7 可降级为 PR3a-ii——已在 Task 7 注明。
