# QUA-218 PR3b — L4 下沉：SessionWriter + MetadataWriter 进 MarpleKit

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`).

**Goal:** 把 L4 写回原语下沉到 MarpleKit/Session/——`SessionWriter`（open-tabs.json 发布）整体迁入，`MetadataWriter`（frontmatter 写穿 IO）从 AppModel.applyPatch 抽出——壳保留瞬时 UI 态与乐观更新编排。行为零变化。

**Architecture:** `SessionWriter` 只依赖 MarpleKit 类型（PersistedWorkspaceSpace/SessionSnapshot/SessionFile），纯迁移 + 公开化。`MetadataWriter` 吃 `VaultClient`（MarpleKit 协议，已有 entryText/writeFile），拥有"取新→变换→原子写"的写穿契约；AppModel.applyPatch 把 IO 三步委托给它，保留乐观 entries 更新、catalog 派生重算、savingField/writeError UI 态。persist() 编排读壳状态、留壳（StateStore/PersistedState 早在 MarpleKit/Nav）。

**Tech Stack:** Swift 6 / swift-testing。`apple/.build` 是符号链接，**永不删**。`swift test` 收尾可能 SIGPIPE exit 13（QUA-208）。基线警告：cblas_sgemv ×1、CollectionGridVariant ×2、Fixtures unhandled ×1——不得新增。**CLAUDE.md tab-sync 提醒**：改 SessionWriter 后须 `make install` + 重启 Mac app，否则运行实例仍发旧格式——终验含此。

---

## 计划级决策（已定）

1. **MetadataWriter = 写穿 IO 边界**，不含字段语义：它只拥有 `write(path:applying:)`（entryText→transform→writeFile）。每字段的 `FrontmatterPatch` 组合 + `Entry.with(...)` 乐观更新 + UI 态留在壳的 `applyPatch`/`set*`——它们耦合壳状态（entries/openEntry/openPath/catalog）。FrontmatterPatch 本就在 MarpleKit/Vault。理由同 PR3a 决策 3：把 orchestration 留壳、只下沉平台-IO 原语，控 blast radius。
2. **SessionWriter 纯迁移**：逐字搬到 MarpleKit/Session/，`final class`→`public final class`、init/publish 公开化；输出格式**逐字不变**（tab-sync 兼容）。AppModel 持有的类型不变（现已是该类，只换 import 来源）。
3. **persist() 留壳**：它读壳状态（savedSpaces/savedViews/sortClauses）构建 PersistedState blob，调 `stateStore.save` + `sessionWriter.publish`。StateStore/PersistedState 已在 MarpleKit/Nav，无需移。本期不动 persist()。
4. **行为零变化**：迁移逐字；applyPatch 的 IO 三步语义（取新文本→patch→原子写、失败 throw 到壳的 catch）逐行等价。

## File Structure

```
apple/Sources/MarpleKit/Session/SessionWriter.swift     ← 迁自 Marple/App/（公开化）
apple/Sources/MarpleKit/Session/MetadataWriter.swift    ← 新：写穿 IO
apple/Sources/Marple/App/SessionWriter.swift            ← 删（迁走）
apple/Sources/Marple/App/AppModel.swift                 ← 改：applyPatch 委托 MetadataWriter；sessionWriter 类型来源换
apple/Tests/MarpleKitTests/MetadataWriterTests.swift    ← 新
apple/Tests/MarpleKitTests/SessionWriterTests.swift     ← 新/迁（若原有壳测）
```

---

### Task 1: SessionWriter 迁入 MarpleKit/Session/

**Files:**
- Move: `apple/Sources/Marple/App/SessionWriter.swift` → `apple/Sources/MarpleKit/Session/SessionWriter.swift`
- Modify: `apple/Sources/Marple/App/AppModel.swift`（import 来源；持有类型不变）

- [ ] **Step 1: git mv + 公开化**

```bash
mkdir -p apple/Sources/MarpleKit/Session
git mv apple/Sources/Marple/App/SessionWriter.swift apple/Sources/MarpleKit/Session/SessionWriter.swift
```
编辑迁入文件：`import MarpleKit` 删除（现在它*是* MarpleKit）；`final class SessionWriter` → `public final class SessionWriter`；`init(workspaceRoot:)`、`func publish(spaces:)` 加 `public`。`@MainActor` 保留。其余**逐字不动**（含 1.5s debounce、lastSpaces 去重、node/leaf 私有助手、flush 的 Task.detached 原子写）。确认它用的全部类型（PersistedWorkspaceSpace、WorkspaceTreeSnapshot、SessionNode/SessionSpaceSnapshot/OpenDocSnapshot、SessionSnapshot、SessionFile、PersistedTab）均 MarpleKit 公开——若有 internal 的，最小公开化并报告。

- [ ] **Step 2: AppModel 适配**

`grep -n "SessionWriter" apple/Sources/Marple/App/AppModel.swift`。`private let sessionWriter: SessionWriter?`（L300）与构造（L330）类型名不变（现在解析到 MarpleKit 的公开类）。AppModel 已 `import MarpleKit`，无需改 import。确认编译。

- [ ] **Step 3: 全量测试**

```bash
cd apple && swift test 2>&1 | tail -3
```
全绿（897）。

- [ ] **Step 4: Commit**

```bash
git add -A apple/Sources
git commit -m "refactor(session): move SessionWriter into MarpleKit/Session (QUA-218)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: MetadataWriter 抽出（写穿 IO，TDD）

**Files:**
- Create: `apple/Sources/MarpleKit/Session/MetadataWriter.swift`
- Test: `apple/Tests/MarpleKitTests/MetadataWriterTests.swift`
- Modify: `apple/Sources/Marple/App/AppModel.swift`（applyPatch 委托）

读 `apple/Sources/MarpleKit/Vault/VaultClient.swift`（协议 `entryText(path:) async throws -> String`、`writeFile(path:text:) async throws`；测试用 `InMemoryVaultClient` 或类似的现成假实现——`VaultClient.swift:105/125` 有一个带 writeLog 的内存实现，确认其名字并复用）。

- [ ] **Step 1: 写失败测试**

```swift
import Testing
@testable import MarpleKit

@MainActor @Suite struct MetadataWriterTests {
    @Test func writeFetchesTransformsAndPersists() async throws {
        let client = <内存 VaultClient>   // 预置 path 的初始文本
        let writer = MetadataWriter(client: client)
        try await writer.write(path: "vault/papers/p.md", applying: { raw in raw + "\nrating: ★★★" })
        let after = try await client.entryText(path: "vault/papers/p.md")
        #expect(after.contains("rating: ★★★"))
    }
    @Test func writePropagatesClientError() async {
        let client = <会在 writeFile 抛错的内存 VaultClient>
        let writer = MetadataWriter(client: client)
        await #expect(throws: (any Error).self) {
            try await writer.write(path: "x", applying: { $0 })
        }
    }
}
```
（用现成的内存 VaultClient 实现；若它不支持预置文本/注错，改用满足 VaultClient 协议的最小测试替身。）

- [ ] **Step 2: 跑测试确认失败**

```bash
cd apple && swift test --filter MetadataWriterTests 2>&1 | tail -3
```

- [ ] **Step 3: 实现 MetadataWriter**

```swift
import Foundation

/// frontmatter 写回的写穿 IO 边界（QUA-218 PR3b L4 下沉）。
/// 拥有"取最新磁盘文本 → 应用变换 → 原子写回"契约；字段语义（FrontmatterPatch
/// 组合）+ 乐观内存更新留在壳的 applyPatch（耦合 entries/UI 态，过渡期留壳）。
/// iOS 只读是产品选择而非平台限制——能力下沉、闲置零成本。
public struct MetadataWriter {
    private let client: VaultClient
    public init(client: VaultClient) { self.client = client }

    /// 取 path 的最新文本，过 transform，写回。任何 IO 失败原样抛出（壳 catch）。
    public func write(path: String, applying transform: (String) -> String) async throws {
        let fresh = try await client.entryText(path: path)
        try await client.writeFile(path: path, text: transform(fresh))
    }
}
```
逐字对应旧 applyPatch 的 L1686-1688（取新→patch→写）。

- [ ] **Step 4: AppModel.applyPatch 委托**

AppModel 加 `private let metadataWriter: MetadataWriter`，在 init 用 `MetadataWriter(client: client)` 构造（client 已是成员）。applyPatch 的 IO 三步：
```swift
            let next = patch(try await client.entryText(path: path))   // 旧
            try await client.writeFile(path: path, text: next)         // 旧
```
改为：
```swift
            try await metadataWriter.write(path: path, applying: patch)
```
**保留**：`savingField`/`writeError`/`defer`、`if let i = entries.firstIndex…{ entries[i] = local(...) }` 乐观更新、`rebuildIndexDerived()/recomputeVisible()/recomputeOpenDerived()`、print、catch。**只**把"取文本+写文件"两行换成一次 metadataWriter.write。语义逐行等价（同样取最新文本、同样 patch、同样写、失败同样落 catch 设 writeError）。

- [ ] **Step 5: 全量 + Commit**

```bash
cd apple && swift test 2>&1 | tail -3
git add -A apple/Sources apple/Tests
git commit -m "refactor(session): MetadataWriter write-through into MarpleKit; applyPatch delegates (QUA-218)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: 终验 + PR

- [ ] **Step 1: macOS 全量 + 警告基线**

```bash
cd apple && swift build 2>&1 | grep "warning:" | sort | uniq -c
cd apple && swift test 2>&1 | tail -3
```
警告 = 基线；测试全绿。

- [ ] **Step 2: iOS 构建**

```bash
cd apple/ios && xcodegen generate && xcodebuild build -project MarpleiOS.xcodeproj -scheme MarpleiOS -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/marple-ios-dd CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```
`BUILD SUCCEEDED`。注意 SessionWriter 现在在 MarpleKit——iOS 共享 MarpleKit 会编译它；确认 iOS 不因 @MainActor SessionWriter 报错（它只在 Mac 实例化，iOS 不调）。

- [ ] **Step 3: make install + GUI 清单（交用户，含 tab-sync 验证）**

```bash
cd apple && make install
```
清单：① 元数据写回——在 Inspector 改 rating/year/title/author/source/doi/themes/image-date，确认写盘成功、列表/关联即时刷新、无 writeError；② **tab-sync（CLAUDE.md 提醒）**——Mac 开几个 tab/Space，确认 iOS 伴侣的"Mac 上打开的"列表仍正确（格式未变）；③ 一般浏览/搜索/关联面板回归正常。

- [ ] **Step 4: push + PR**

```bash
git push -u origin qua-218-pr3b
gh pr create --title "refactor(session): L4 下沉 — SessionWriter + MetadataWriter 进 MarpleKit (QUA-218, PR3b)" --body "<见下>"
```
PR body：SessionWriter 纯迁移（格式逐字不变，tab-sync 兼容）；MetadataWriter 抽出写穿 IO，applyPatch 委托 IO 三步、保留乐观更新+派生+UI 态；persist 编排与字段语义留壳（过渡，决策 1/3）；行为零变化；897+ 测试绿，iOS 构建过。

---

## Self-Review 记录

- **Spec 覆盖**：§3.5「SessionWriter/MetadataWriter 下沉 MarpleKit」→ Task 1/2；SessionStore 已在 Nav/（决策 3，无需移）；CLI handler 本就在 MarpleKit（spec §3.5，本期无关）。
- **Placeholder**：测试的内存 VaultClient 以"用现成实现/最小替身"指明，源在 VaultClient.swift:105。
- **类型一致**：`MetadataWriter(client:)`/`write(path:applying:)`、`public final class SessionWriter`/`publish(spaces:)` 各处一致。
- **零变化**：applyPatch 仅替换 IO 两行为 metadataWriter.write，其余逐行保留；SessionWriter 逐字搬。
- **tab-sync 风险**：终验显式含 make install + iOS 列表验证（CLAUDE.md 提醒）。
