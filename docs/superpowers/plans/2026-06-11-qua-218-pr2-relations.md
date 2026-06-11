# QUA-218 PR2 — L2 关联：NameResolver + RelationGraph + 规则引擎 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把四套名字匹配器归一为 NameResolver、散落的关联派生收拢为 RelationGraph（规则①实体引用）与容器规则（规则②），替换七处胶水；除已获用户批准的三条"只增不改"匹配差异外行为零变化。

**Architecture:** 全部新代码落在 `MarpleKit/Catalog/`（由 `Derivation/` 改名）。NameResolver 是无状态算法集：每个匹配器的第一级逐字保留旧算法（旧命中 winner 不变），第二级共用宽松归一（去变音符+空白折叠），只在第一级无命中时兜底。RelationGraph 预建 authoredBy/annotates 双向边 + 名字键 works 索引，由 AppModel 的 deferred rebuild 构建（替代 authorIndex/annotationIndex 两张字典）。规则②为 containerContext（book/topic 共用 slug-文件夹核心），bookContext/topicContext 保持公开签名作投影，视图零改动。

**Tech Stack:** Swift 6 / swift-testing（`@Suite`/`@Test`/`#expect`，**不是 XCTest**）。仓库根：本 worktree；包在 `apple/`。`apple/.build` 是符号链接，**永远不许删**。`swift test` 收尾可能 SIGPIPE exit 13（QUA-208，已知，看测试汇总行判断成败）。

---

## 计划级决策（已定，执行者不需要再判断）

1. **用户已批准的三条匹配差异（全部"以前不命中→现在命中"，无 winner 改变）**：
   ① 作者页解析获得变音符不敏感（`Pierré`↔`Pierre`）；② 作者页解析获得空白折叠（双空格/换行归一）；③ wikilink 同获两者（`[[Cafe]]`→`Café` 页）。**其余一切逐字等价。**
2. **folded 第二级只用于"页面解析"**（authorProfile/works 边/wikilink）。**siblings 的同名作品分组保持 exact 键**（`worksByAuthorKey`，即旧 `buildAuthorIndex` 逐字）——把折叠推广到分组不在批准范围内。
3. **journal 匹配器已是最严谨形态，逐字搬入 NameResolver，不加第二级**（它本身就是 folded 规则的来源）。
4. **RelationGraph 本期只含 `authoredBy` + `annotates` 两类边**。topic 成员关系保留现有 `TopicMembership`（slug 键双向索引，本就干净，且 spec 的"七处胶水"删除清单不含 TopicIndex）；paper→journal 保持 Inspector 渲染时按需查询（搬进 NameResolver 即可）——否则会把"立即可见"变成"deferred 后可见"，违反行为零变化。两者在 PR3 Catalog 接管惰性调度后再入图。
5. **authoredBy 边对同名多页"全连"**：一个名字在获胜层级匹配到多个作者页时，向每页都建边。正向消费者取 `.first`（= 旧 `entries.first` 扫描序），反向消费者各自看到自己的边（= 旧的按 title 键查询，两页同名时各自都有 works）。这是为了逐字等价，不是特性。
6. **annotations 不做空图回退**：旧代码里 `annotationIndex` 没有 isEmpty 回退（deferred 未完成时就是空列表），新代码保持——`relations()` 的 author 部分用 `liveGraph`（isEmpty 时同步重建，对应旧 line 92 回退），annotations 只读传入的图。时序逐字保真。
7. **容器根目录（`vault/books/` 等）保持代码常量**，本期不进 schema.yaml：没有真实覆盖需求，把根目录变成配置纯属投机（"表不是引擎"反着用）。spec §3.3 的容器约定条目以"规则②机制统一"满足，根目录声明化留给真需求出现时。
8. **talk↔transcript 配对（`siblingEntry`）**：搬进 Kit 的 Containers.swift 作有名字的配对规则（目录+固定文件名，3 行路径运算），**不**强行套 slug-容器机制——零行为收益，纯加机器。
9. **ThemeIndex"关联部分"= 无事可做**：侦察确认 ThemeIndex 只有 counts，无关联结构。PR body 注明。
10. **`annotationAnchor`（章→书 overview 锚点重映射）保持公开的有名字例外**，被 RelationGraph.build 与 relations() 共用。

## File Structure

```
apple/Sources/MarpleKit/Catalog/          ← Derivation/ 改名（Task 1）
  NameResolver.swift                       ← 新（Task 2）：三个匹配器 + folded 第二级
  RelationGraph.swift                      ← 新（Task 4）：边 + worksByAuthorKey + build
  Containers.swift                         ← 新（Task 6）：containerContext + siblingEntry
  RelationsIndex.swift                     ← Task 5 改：relations() 改读图；删 buildAuthorIndex/buildAnnotationIndex 公开函数
  BookContext.swift / TopicContext.swift   ← Task 6 改：结构体保留，构造改为 containerContext 投影
  （其余 SearchRanker/Browse/ThemeIndex/TopicIndex 等原样随目录改名）
apple/Sources/MarpleKit/Markdown/Wikilink.swift   ← Task 3 改：删 WikiResolver.resolve（tokenize/protect 不动）
apple/Sources/Marple/App/AppModel.swift           ← Task 3+5 改：wikilink 调用点、authorProfile 转发、relationGraph 属性
apple/Sources/Marple/Inspector/InspectorMetadataRows.swift ← Task 3+6 改：删本地 journalEntry/siblingEntry 及私有归一化助手
apple/Tests/MarpleKitTests/NameResolverTests.swift   ← 新
apple/Tests/MarpleKitTests/RelationGraphTests.swift  ← 新
apple/Tests/MarpleKitTests/ContainersTests.swift     ← 新
apple/Tests/MarpleKitTests/RelationsIndexTests.swift ← Task 5 适配新签名（断言不变）
```

---

### Task 1: Derivation/ 改名 Catalog/（零逻辑）

**Files:**
- Move: `apple/Sources/MarpleKit/Derivation/` → `apple/Sources/MarpleKit/Catalog/`（整目录）
- Modify: `apple/ARCHITECTURE.md`

- [ ] **Step 1: git mv**

```bash
cd <worktree 根>
git mv apple/Sources/MarpleKit/Derivation apple/Sources/MarpleKit/Catalog
```

- [ ] **Step 2: 更新 ARCHITECTURE.md**

`grep -n "Derivation" apple/ARCHITECTURE.md`，把目录条目改为 `Catalog/`，描述措辞（贴合文档现有风格）：

> `Catalog/` — 编目层（L2）：全部"由馆藏派生"的索引与关联（搜索、关系图、容器上下文、theme counts）。QUA-218 中由 `Derivation/` 改名；Catalog 类型本体在 PR3 立起。

如有"横向依赖"句提及 Derivation 也同步改名。

- [ ] **Step 3: 全量测试**

```bash
cd apple && swift test 2>&1 | tail -3
```
Expected: 846 tests 全绿（SPM 按 target 整目录编译，无配置可改）。

- [ ] **Step 4: Commit**

```bash
git add -A apple/Sources/MarpleKit apple/ARCHITECTURE.md
git commit -m "refactor(catalog): rename Derivation/ to Catalog/ (QUA-218)"
```

---

### Task 2: NameResolver（三匹配器归一，TDD）

**Files:**
- Create: `apple/Sources/MarpleKit/Catalog/NameResolver.swift`
- Test: `apple/Tests/MarpleKitTests/NameResolverTests.swift`

源算法位置（第一级必须逐字等价于它们）：
- wikilink 旧算法：`apple/Sources/MarpleKit/Markdown/Wikilink.swift` 的 `WikiResolver.resolve`（小写 title 全等 → 小写文件名 stem 全等；**不 trim**）
- 作者页旧算法：`RelationsIndex.swift:115-118` 与 `AppModel.swift:1890-1896`（name 小写+trim，title 小写**不 trim**，全等，`entries.first`）
- journal 旧算法：`InspectorMetadataRows.swift:271-316` 的 `journalEntry` + `journalSlug` + `fileStem` + `journalKeys` + `normalizedJournalKey` + `slugKey` + `nonEmpty`（**整组逐字搬入**）

- [ ] **Step 1: 写失败测试**

新建 `NameResolverTests.swift`（swift-testing；Entry 工厂照抄 `RelationsIndexTests.swift` 顶部的 `mk()`，含 path/type/title 参数即可）：

```swift
import Testing
@testable import MarpleKit

@Suite struct NameResolverTests {
    private func mk(path: String, type: EntryType, title: String? = nil,
                    journal: String? = nil) -> Entry {
        // 照抄 RelationsIndexTests 的 mk，补 journal 参数（Entry 已有该字段）
    }

    // — 作者页：第一级逐字（旧行为不变） —
    @Test func authorProfileExactMatchUnchanged() {
        let page = mk(path: "vault/authors/pb.md", type: .author, title: "Pierre Bourdieu")
        #expect(NameResolver.authorProfile(named: " pierre bourdieu ", in: [page])?.path == page.path)
    }
    @Test func authorProfileExactBeatsFolded() {
        // 同时存在精确命中页与仅折叠命中页时，精确页赢（且 winner 不因第二级改变）
        let exact = mk(path: "vault/authors/a.md", type: .author, title: "Pierre Bourdieu")
        let folded = mk(path: "vault/authors/b.md", type: .author, title: "Pierré Bourdieu")
        #expect(NameResolver.authorProfile(named: "Pierre Bourdieu", in: [folded, exact])?.path == exact.path)
    }
    // — 批准差异①：变音符 —
    @Test func authorProfileFoldsDiacritics() {
        let page = mk(path: "vault/authors/pb.md", type: .author, title: "Pierré Bourdieu")
        #expect(NameResolver.authorProfile(named: "Pierre Bourdieu", in: [page])?.path == page.path)
    }
    // — 批准差异②：空白折叠 —
    @Test func authorProfileCollapsesWhitespace() {
        let page = mk(path: "vault/authors/pb.md", type: .author, title: "Pierre Bourdieu")
        #expect(NameResolver.authorProfile(named: "Pierre  Bourdieu", in: [page])?.path == page.path)
    }
    @Test func authorProfileTypeRestricted() {
        let notAuthor = mk(path: "vault/papers/x.md", type: .paper, title: "Pierre Bourdieu")
        #expect(NameResolver.authorProfile(named: "Pierre Bourdieu", in: [notAuthor]) == nil)
    }
    @Test func authorPagesReturnsAllAtWinningTier() {
        let a = mk(path: "vault/authors/a.md", type: .author, title: "John Smith")
        let b = mk(path: "vault/authors/b.md", type: .author, title: "john smith")
        #expect(NameResolver.authorPages(named: "John Smith", in: [a, b]).map(\.path) == [a.path, b.path])
    }

    // — wikilink：第一级逐字（title 优先于 stem，不 trim） —
    @Test func wikilinkTitleBeatsStem() {
        let byTitle = mk(path: "vault/notes/x.md", type: .note, title: "Target")
        let byStem  = mk(path: "vault/notes/target.md", type: .note, title: "Other")
        #expect(NameResolver.resolveWikilink("target", in: [byStem, byTitle])?.path == byTitle.path)
    }
    @Test func wikilinkStemFallbackUnchanged() {
        let byStem = mk(path: "vault/notes/target.md", type: .note, title: "Other")
        #expect(NameResolver.resolveWikilink("Target", in: [byStem])?.path == byStem.path)
    }
    // — 批准差异③ —
    @Test func wikilinkFoldsDiacriticsAsLastResort() {
        let page = mk(path: "vault/notes/cafe-note.md", type: .note, title: "Café")
        #expect(NameResolver.resolveWikilink("Cafe", in: [page])?.path == page.path)
    }
    @Test func wikilinkExactStemBeatsFoldedTitle() {
        let foldedTitle = mk(path: "vault/notes/x.md", type: .note, title: "Café")
        let exactStem   = mk(path: "vault/notes/cafe.md", type: .note, title: "Other")
        #expect(NameResolver.resolveWikilink("cafe", in: [foldedTitle, exactStem])?.path == exactStem.path)
    }

    // — journal：逐字搬入（新增覆盖，行为=旧 Inspector 实现） —
    @Test func journalMatchesByJournalField() {
        let j = mk(path: "vault/journals/jop.md", type: .journal, journal: "Journal of Philosophy")
        #expect(NameResolver.journalEntry(matching: "journal of philosophy", in: [j])?.path == j.path)
    }
    @Test func journalMatchesBySlugForm() {
        let j = mk(path: "vault/journals/jop.md", type: .journal, title: "Journal of Philosophy")
        #expect(NameResolver.journalEntry(matching: "Journal-of-Philosophy", in: [j])?.path == j.path)
    }
    @Test func journalMatchesByPathStem() {
        let j = mk(path: "vault/journals/critical-inquiry.md", type: .journal)
        #expect(NameResolver.journalEntry(matching: "Critical Inquiry", in: [j])?.path == j.path)
    }
    @Test func journalTypeRestricted() {
        let p = mk(path: "vault/papers/x.md", type: .paper, title: "Mind")
        #expect(NameResolver.journalEntry(matching: "Mind", in: [p]) == nil)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd apple && swift test --filter NameResolverTests 2>&1 | tail -3
```
Expected: 编译失败（NameResolver 不存在）。

- [ ] **Step 3: 实现 NameResolver.swift**

```swift
import Foundation

/// 全库唯一的名字归一/匹配器（QUA-218 规则①的解析端）。
///
/// 统一结构：每个匹配器的第一级**逐字保留**它被收拢前的算法（旧命中 winner
/// 永不改变）；第二级共用 `foldedKey`（去变音符 + 空白折叠 + 小写），只在
/// 第一级零命中时兜底。这把归一差异压成"只增不改"——用户已批准的三条新增
/// 命中见 NameResolverTests。journal 匹配器本身就是 folded 规则的来源，
/// 逐字搬入、无第二级。
public enum NameResolver {

    /// 宽松归一键：trim → 去变音符/大小写折叠 → 空白折叠 → 小写。
    /// 与 journal 匹配器的 normalizedJournalKey 同款。
    static func foldedKey(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = trimmed.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return folded
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()
    }

    // MARK: - 作者页

    /// 获胜层级的全部匹配作者页（文档序）。第一级 = 旧 RelationsIndex 扫描
    /// （name 小写+trim vs title 小写）；第二级 = foldedKey 相等。
    /// 返回"全部"而非首个：RelationGraph 对同名多页全连边以保持旧的
    /// 按-title-键查询语义（见计划决策 5）。
    public static func authorPages(named name: String, in entries: [Entry]) -> [Entry] {
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return [] }
        let exact = entries.filter { $0.type == .author && ($0.title ?? "").lowercased() == key }
        if !exact.isEmpty { return exact }
        let folded = foldedKey(name)
        guard !folded.isEmpty else { return [] }
        return entries.filter { $0.type == .author && foldedKey($0.title ?? "") == folded }
    }

    /// 首个匹配作者页（= 旧 entries.first 扫描，外加批准的 folded 兜底）。
    public static func authorProfile(named name: String, in entries: [Entry]) -> Entry? {
        authorPages(named: name, in: entries).first
    }

    // MARK: - wikilink

    /// [[target]] → 条目。第一级逐字 = 旧 WikiResolver.resolve（小写 title
    /// 全等 → 小写文件名 stem 全等，均不 trim）；第二级同链 folded。
    public static func resolveWikilink(_ target: String, in entries: [Entry]) -> Entry? {
        let needle = target.lowercased()
        if let byTitle = entries.first(where: { ($0.title ?? "").lowercased() == needle }) {
            return byTitle
        }
        if let byStem = entries.first(where: { fileStem($0.path).lowercased() == needle }) {
            return byStem
        }
        let folded = foldedKey(target)
        guard !folded.isEmpty else { return nil }
        if let byTitle = entries.first(where: { foldedKey($0.title ?? "") == folded }) {
            return byTitle
        }
        return entries.first { foldedKey(fileStem($0.path)) == folded }
    }

    // MARK: - journal（逐字搬自 InspectorMetadataRows，QUA-218 收拢进 Kit）

    public static func journalEntry(matching value: String, in entries: [Entry]) -> Entry? {
        let needle = journalKeys(value)
        guard !needle.isEmpty else { return nil }
        return entries.first { entry in
            guard entry.type == .journal else { return false }
            let keys = journalKeys(entry.journal)
                .union(journalKeys(entry.title))
                .union(journalKeys(journalSlug(entry.path)))
                .union(journalKeys(fileStem(entry.path)))
            return !needle.isDisjoint(with: keys)
        }
    }

    private static func journalSlug(_ rel: String) -> String? {
        guard rel.hasPrefix("vault/journals/") else { return nil }
        let rest = String(rel.dropFirst("vault/journals/".count))
        guard let first = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first else {
            return nil
        }
        return String(first).replacingOccurrences(of: ".md", with: "")
    }

    private static func fileStem(_ rel: String) -> String {
        (rel as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
    }

    private static func journalKeys(_ value: String?) -> Set<String> {
        guard let key = normalizedJournalKey(value) else { return [] }
        var keys: Set<String> = [key]
        let slug = slugKey(key)
        if !slug.isEmpty { keys.insert(slug) }
        return keys
    }

    private static func normalizedJournalKey(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        let folded = trimmed.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let collapsed = folded.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return collapsed.lowercased()
    }

    private static func slugKey(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
```

注意：`authorPages` 第一级用 `filter` 替代旧 `first` 但谓词逐字相同——多命中时文档序保留，`first` 语义不变。

- [ ] **Step 4: 跑测试确认通过 + 全量**

```bash
cd apple && swift test --filter NameResolverTests 2>&1 | tail -3
cd apple && swift test 2>&1 | tail -3
```

- [ ] **Step 5: Commit**

```bash
git add apple/Sources/MarpleKit/Catalog/NameResolver.swift apple/Tests/MarpleKitTests/NameResolverTests.swift
git commit -m "feat(catalog): NameResolver — unified two-tier name matching (QUA-218)"
```

---

### Task 3: 接线三处调用点（wikilink / authorProfile / journal）

**Files:**
- Modify: `apple/Sources/MarpleKit/Markdown/Wikilink.swift`（删 `WikiResolver` enum 整个；`Wikilink` enum 的 tokenize/protect/restore/preprocessForRendering 不动）
- Modify: `apple/Sources/Marple/App/AppModel.swift:1137`、`:1640`、`:1890-1896`
- Modify: `apple/Sources/Marple/Inspector/InspectorMetadataRows.swift`（删 `journalEntry`/`journalSlug`/`fileStem`/`journalKeys`/`normalizedJournalKey`/`slugKey` 六个私有函数；`nonEmpty`、`journalDisplayTitle`、`displayTitle` 保留——它们是显示助手不是匹配器）

- [ ] **Step 1: AppModel 两处 wikilink 调用**

`AppModel.swift:1137`：
```swift
guard let hit = NameResolver.resolveWikilink(target, in: entries) else {
```
`AppModel.swift:1640`：
```swift
guard let resolved = NameResolver.resolveWikilink(ref.target, in: entries) else { continue }
```

- [ ] **Step 2: AppModel.authorProfile 转发**

`AppModel.swift:1887-1896` 整个方法体替换为（签名与 doc comment 保留，注明转发）：
```swift
    /// Author-profile entry whose title matches `name`. Forwards to
    /// NameResolver (exact tier = the old scan; folded tier per QUA-218 PR2
    /// approved diffs ①②). Used by the Inspector author chips.
    func authorProfile(for name: String) -> Entry? {
        NameResolver.authorProfile(named: name, in: entries)
    }
```

- [ ] **Step 3: 删 WikiResolver.resolve**

`Wikilink.swift` 中 `WikiResolver` enum（约 :92-107）整个删除。先 `grep -rn "WikiResolver" apple/Sources apple/Tests apple/ios` 确认仅 AppModel 两处（已改）；若 iOS 或测试有引用，同样改为 `NameResolver.resolveWikilink`。

- [ ] **Step 4: Inspector journal 调用**

`InspectorMetadataRows.swift:108`：
```swift
        if let target = NameResolver.journalEntry(matching: journal, in: entries) {
```
然后删除文件底部 `journalEntry`/`journalSlug`/`fileStem`/`journalKeys`/`normalizedJournalKey`/`slugKey` 六个私有函数（:271-316）。`grep -n "slugKey\|journalKeys\|fileStem" apple/Sources/Marple/` 确认无残余引用（注意 `fileStem` 若被 `displayTitle` 等使用则保留该助手——以 grep 为准，只删真正无主的）。

- [ ] **Step 5: 全量测试 + Commit**

```bash
cd apple && swift test 2>&1 | tail -3
git add -A apple/Sources
git commit -m "refactor(catalog): wire wikilink/author/journal call sites to NameResolver (QUA-218)"
```

---

### Task 4: RelationGraph + 规则①（TDD，先不接线）

**Files:**
- Create: `apple/Sources/MarpleKit/Catalog/RelationGraph.swift`
- Test: `apple/Tests/MarpleKitTests/RelationGraphTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
import Testing
@testable import MarpleKit

@Suite struct RelationGraphTests {
    // mk 工厂照抄 RelationsIndexTests（path/type/title/author/book/annotates 参数）

    @Test func authoredByForwardAndReverse() {
        let page = mk(path: "vault/authors/smith.md", type: .author, title: "Smith")
        let paper = mk(path: "vault/papers/p.md", type: .paper, author: ["Smith"])
        let g = RelationGraph.build([page, paper])
        #expect(g.targets(of: paper.path, kind: .authoredBy).map(\.path) == [page.path])
        #expect(g.sources(of: page.path, kind: .authoredBy).map(\.path) == [paper.path])
    }
    @Test func duplicateAuthorPagesBothGetWorks() {
        // 旧行为：works 按 title 键查询，两同名页看到同一列表 → 全连边保持等价
        let a = mk(path: "vault/authors/a.md", type: .author, title: "Smith")
        let b = mk(path: "vault/authors/b.md", type: .author, title: "smith")
        let paper = mk(path: "vault/papers/p.md", type: .paper, author: ["Smith"])
        let g = RelationGraph.build([a, b, paper])
        #expect(g.sources(of: a.path, kind: .authoredBy).map(\.path) == [paper.path])
        #expect(g.sources(of: b.path, kind: .authoredBy).map(\.path) == [paper.path])
        // 正向 first = 文档序首页（旧 entries.first 语义）
        #expect(g.targets(of: paper.path, kind: .authoredBy).first?.path == a.path)
    }
    @Test func foldedTierOnlyWhenNoExactPage() {
        let folded = mk(path: "vault/authors/pb.md", type: .author, title: "Pierré Bourdieu")
        let paper = mk(path: "vault/papers/p.md", type: .paper, author: ["Pierre Bourdieu"])
        let g = RelationGraph.build([folded, paper])
        #expect(g.sources(of: folded.path, kind: .authoredBy).map(\.path) == [paper.path])
    }
    @Test func authoredByOnlyFromPapersAndBooks() {
        let page = mk(path: "vault/authors/smith.md", type: .author, title: "Smith")
        let note = mk(path: "vault/notes/n.md", type: .note, author: ["Smith"])
        let g = RelationGraph.build([page, note])
        #expect(g.sources(of: page.path, kind: .authoredBy).isEmpty)
    }
    @Test func worksByAuthorKeyMatchesLegacyAuthorIndex() {
        // siblings 不需要作者页存在（exact 名字键，= 旧 buildAuthorIndex）
        let p1 = mk(path: "vault/papers/a.md", type: .paper, author: ["Jane Doe"])
        let p2 = mk(path: "vault/papers/b.md", type: .paper, author: ["jane doe"])
        let g = RelationGraph.build([p1, p2])
        #expect(g.worksByAuthorKey["jane doe"]?.map(\.path) == [p1.path, p2.path])
    }
    @Test func annotatesEdgeWithChapterAnchorRemap() {
        let overview = mk(path: "vault/books/b/00-overview.md", type: .book)
        let chapter = mk(path: "vault/books/b/01-c.md", type: .chapter, book: "b")
        let note = mk(path: "vault/notes/n.md", type: .note, annotates: chapter.path)
        let g = RelationGraph.build([overview, chapter, note])
        // 章被标注 → 锚点重映射到书 overview（有名字的例外，annotationAnchor）
        #expect(g.sources(of: overview.path, kind: .annotates).map(\.path) == [note.path])
        #expect(g.targets(of: note.path, kind: .annotates).map(\.path) == [overview.path])
    }
    @Test func annotatesDanglingTargetKeepsRawPath() {
        // 旧 buildAnnotationIndex：目标不在索引时按原始路径入键
        let note = mk(path: "vault/notes/n.md", type: .note, annotates: "vault/papers/gone.md")
        let g = RelationGraph.build([note])
        #expect(g.sources(of: "vault/papers/gone.md", kind: .annotates).map(\.path) == [note.path])
    }
    @Test func emptyAndIsEmpty() {
        #expect(RelationGraph.empty.isEmpty)
        #expect(!RelationGraph.build([mk(path: "vault/papers/p.md", type: .paper, author: ["X"]),
                                      mk(path: "vault/authors/x.md", type: .author, title: "X")]).isEmpty)
    }
}
```

- [ ] **Step 2: 确认编译失败**

```bash
cd apple && swift test --filter RelationGraphTests 2>&1 | tail -3
```

- [ ] **Step 3: 实现 RelationGraph.swift**

```swift
import Foundation

/// 关联边的种类。本期只有规则①产出的两类（计划决策 4）：
/// topic 成员走 TopicMembership（slug 键），journal 链接按需查询。
public enum RelationKind: String, Sendable, Hashable {
    case authoredBy   // 作品(paper/book) → 作者页；position = author 数组下标
    case annotates    // 笔记 → 标注锚点（章→书 overview 重映射已烘焙）
}

/// (from, kind, to, position?) 正反双向索引 —— L2 关联的唯一预建存储。
/// 由 AppModel 的 deferred rebuild 构建（替代旧 authorIndex/annotationIndex
/// 两张字典）；PR3 起由 Catalog 接管构建调度。
public struct RelationGraph: Sendable, Equatable {
    public struct Edge: Sendable, Equatable, Hashable {
        public let from: String
        public let kind: RelationKind
        public let to: String
        public let position: Int?
        public init(from: String, kind: RelationKind, to: String, position: Int? = nil) {
            self.from = from; self.kind = kind; self.to = to; self.position = position
        }
    }

    /// 名字键(小写) → 作品列表。逐字 = 旧 buildAuthorIndex：siblings（同名
    /// 作品分组）不要求作者页存在，所以必须按名字键、且只用 exact 层
    /// （folded 不推广到分组，批准范围外）。
    public let worksByAuthorKey: [String: [Entry]]

    private let edges: [Edge]
    private let byFrom: [String: [Edge]]          // kind 混存，查询时过滤
    private let byTo: [String: [Edge]]
    private let entriesByPath: [String: Entry]

    public static let empty = RelationGraph(edges: [], worksByAuthorKey: [:], entriesByPath: [:])
    public var isEmpty: Bool { edges.isEmpty && worksByAuthorKey.isEmpty }

    private init(edges: [Edge], worksByAuthorKey: [String: [Entry]], entriesByPath: [String: Entry]) {
        self.edges = edges
        self.worksByAuthorKey = worksByAuthorKey
        self.entriesByPath = entriesByPath
        var f: [String: [Edge]] = [:], t: [String: [Edge]] = [:]
        for e in edges {
            f[e.from, default: []].append(e)
            t[e.to, default: []].append(e)
        }
        self.byFrom = f; self.byTo = t
    }

    /// 正向：from 的目标条目（建边序 = 字段序×页文档序；.first 即旧
    /// entries.first 扫描语义）。
    public func targets(of path: String, kind: RelationKind) -> [Entry] {
        (byFrom[path] ?? []).filter { $0.kind == kind }.compactMap { entriesByPath[$0.to] }
    }

    /// 反向：指向 to 的来源条目（文档序，= 旧索引插入序）。
    public func sources(of path: String, kind: RelationKind) -> [Entry] {
        (byTo[path] ?? []).filter { $0.kind == kind }.compactMap { entriesByPath[$0.from] }
    }

    /// 规则①实体引用 + annotates 例外，一次线性扫描建图。
    public static func build(_ entries: [Entry]) -> RelationGraph {
        var edges: [Edge] = []
        var works: [String: [Entry]] = [:]
        var byPath: [String: Entry] = [:]
        for e in entries where byPath[e.path] == nil { byPath[e.path] = e }

        for e in entries {
            // worksByAuthorKey：逐字 = 旧 buildAuthorIndex
            if e.type == .paper || e.type == .book {
                for name in e.author {
                    works[name.lowercased(), default: []].append(e)
                }
                // authoredBy 边：获胜层级全连（计划决策 5）
                for (i, name) in e.author.enumerated() {
                    for page in NameResolver.authorPages(named: name, in: entries) {
                        edges.append(Edge(from: e.path, kind: .authoredBy, to: page.path, position: i))
                    }
                }
            }
            // annotates：逐字 = 旧 buildAnnotationIndex（含悬空目标按原路径）
            if e.type == .note, let target = e.annotates, !target.isEmpty {
                let anchor = byPath[target].map { annotationAnchor(for: $0, in: entries).path } ?? target
                edges.append(Edge(from: e.path, kind: .annotates, to: anchor))
            }
        }
        // 悬空 annotates 目标也要能反查 —— sources() 取 from 侧条目，
        // entriesByPath 已含全部条目，无需补。
        return RelationGraph(edges: edges, worksByAuthorKey: works, entriesByPath: byPath)
    }
}
```

实现注意：
- `annotationAnchor(for:in:)` 是 `RelationsIndex.swift:31` 现有公开函数，直接复用（它内部每次重建 overviewBySlug，O(n)；build 内逐 note 调用 = O(notes×n)。如测试或现状显示这成为问题，可在 build 里手工内联 overviewBySlug 一次性构建——`RelationsIndex.swift:37-48` 的 `buildAnnotationIndex` 正是这么做的，照抄它的结构即可，行为相同）。**优先照抄 buildAnnotationIndex 的结构**（一次 `bookOverviewBySlug` + 私有 anchor 重载），把 `bookOverviewBySlug`/私有 `annotationAnchor(for:overviewBySlug:)` 从 RelationsIndex.swift 一并迁来或改为 internal 共享——以最小 diff 为准。
- `NameResolver.authorPages` 每名字 O(n) 扫描×全库 = O(works×names×n)，与旧 `relations()` 里逐次 `entries.first` 同量级但移到了 deferred 后台，可接受；不要提前优化。

- [ ] **Step 4: 测试通过 + 全量**

```bash
cd apple && swift test --filter RelationGraphTests 2>&1 | tail -3
cd apple && swift test 2>&1 | tail -3
```

- [ ] **Step 5: Commit**

```bash
git add apple/Sources/MarpleKit/Catalog/RelationGraph.swift apple/Tests/MarpleKitTests/RelationGraphTests.swift
git commit -m "feat(catalog): RelationGraph — rule-1 entity-reference edges (QUA-218)"
```

---

### Task 5: relations() 改读图 + AppModel 接线（删两张旧索引）

**Files:**
- Modify: `apple/Sources/MarpleKit/Catalog/RelationsIndex.swift`
- Modify: `apple/Sources/Marple/App/AppModel.swift:202-203`（属性）、`:539-562`（deferred rebuild）、`:575-580`（recomputeOpenDerived）
- Modify: `apple/Tests/MarpleKitTests/RelationsIndexTests.swift`（适配签名，断言不变）

- [ ] **Step 1: 先改测试（红）**

`RelationsIndexTests.swift` 中所有 `relations(for:in:authorIndex:annotationIndex:topicMembership:)` 调用改为：

```swift
relations(for: entry, in: entries,
          graph: RelationGraph.build(entries),
          topicMembership: buildTopicMembership(entries))   // 原传了的保持原参
```
原来传 `authorIndex: [:], annotationIndex: [:]`（依赖空回退）的测试改传 `graph: .empty` ——它们验证的就是回退路径。**断言一律不动**。同时把直接测 `buildAuthorIndex`/`buildAnnotationIndex` 的测试改为对等的图断言：
- `buildAuthorIndex` 断言 → `RelationGraph.build(entries).worksByAuthorKey` 同断言；
- `buildAnnotationIndex` 断言 → `g.sources(of: 目标路径, kind: .annotates)` 路径列表断言。

```bash
cd apple && swift test --filter RelationsIndexTests 2>&1 | tail -3   # Expected: 编译失败
```

- [ ] **Step 2: 改 relations() 签名与实现**

`RelationsIndex.swift:87-142` 替换为（**只动数据来源，过滤/排序/例外逐行保留**）：

```swift
/// Compute knowledge relations for `entry`. Ports the PropertyPanel backlinks memo.
public func relations(for entry: Entry, in entries: [Entry],
                      graph: RelationGraph,
                      topicMembership: TopicMembership = TopicMembership()) -> Relations {
    var out = Relations()
    // 旧 line 92 的 isEmpty 回退：deferred 图未就绪时同步重建（author 部分用）。
    // annotations 沿用旧时序：只读传入的图，未就绪即空（旧 annotationIndex 无回退）。
    let liveGraph = graph.isEmpty ? RelationGraph.build(entries) : graph
    let anchor = annotationAnchor(for: entry, in: entries)
    out.annotations = graph.sources(of: anchor.path, kind: .annotates).sorted(by: byRatingDesc)

    if entry.type == .topic, let slug = topicSlug(entry.path) {
        out.topicMembers = (topicMembership.membersBySlug[slug] ?? [])
            .filter { $0.path != entry.path && relationPanelType($0) != nil }
            .sorted(by: byRatingDesc)
    }

    if entry.type == .author {
        out.works = liveGraph.sources(of: entry.path, kind: .authoredBy)
            .filter { $0.path != entry.path }
            .sorted(by: byRatingDesc)
    }

    let relationEntry = entry.type == .chapter ? bookContext(for: entry, in: entries)?.overview : entry
    if let relationEntry, relationEntry.type == .paper || relationEntry.type == .book {
        out.authorProfile = liveGraph.targets(of: relationEntry.path, kind: .authoredBy).first
        var siblings: [Entry] = []
        var seen = Set<String>()
        for name in relationEntry.author {
            let key = name.lowercased()
            for w in liveGraph.worksByAuthorKey[key] ?? []
                where w.path != relationEntry.path
                    && w.path != entry.path
                    && relationPanelType(w) != nil
                    && !seen.contains(w.path) {
                seen.insert(w.path); siblings.append(w)
            }
        }
        out.siblings = siblings.sorted(by: byRatingDesc)

        let own = Set(relationEntry.themes)
        if own.count >= 2 {
            var scored: [(n: Int, entry: Entry)] = []
            for e in entries where e.path != relationEntry.path && e.path != entry.path && e.type == relationEntry.type {
                let n = e.themes.filter { own.contains($0) }.count
                if n >= 2 { scored.append((n, e)) }
            }
            scored.sort { $0.n != $1.n ? $0.n > $1.n : $0.entry.ratingScore > $1.entry.ratingScore }
            out.similar = scored.prefix(6).map(\.entry)
        }
    }
    return out
}
```

等价性论证（执行者自检，已由计划验证）：
- `works`：旧 = `authorIndex[lc(title)]`；新 = 反向边。exact 情形边集 = "名字 lc== 页 title lc 的全部作品" = 旧键查询（含同名多页，全连保证）。folded 新增命中 = 批准差异①②。
- `authorProfile`：旧 = 按名字序首个 `entries.first` 命中页；新 = 正向边 first（边序 = 名字序×页文档序）。
- `siblings`：`worksByAuthorKey` 逐字 = 旧 `liveAuthorIndex`。
- 旧 `out.authorProfile` 在 siblings 循环内赋值（首个有命中的名字）；新 targets-first 等价，且 folded 兜底为批准差异。

然后删除 `buildAuthorIndex`（:20-29）与 `buildAnnotationIndex`（:37-48）两个公开函数（worksByAuthorKey 与 annotates 边已接管；若 Task 4 把 `bookOverviewBySlug` 迁去了 RelationGraph.swift，这里只剩删除）。`annotationAnchor(for:in:)` 公开版**保留**（relations() 与图构建共用的有名字例外）。`splitAuthors` 不动。
`grep -rn "buildAuthorIndex\|buildAnnotationIndex" apple/Sources apple/Tests` 确认零残余。

- [ ] **Step 3: AppModel 接线**

属性（:202-203）：
```swift
    private(set) var relationGraph: RelationGraph = .empty
```
（删 `authorIndex`/`annotationIndex` 两行；`grep -n "authorIndex\|annotationIndex" apple/Sources/Marple/` 找全部使用点——预期仅 deferred rebuild 与 recomputeOpenDerived。）

deferred rebuild（:539-562 内）：
```swift
            let result = await Task.detached(priority: .utility) {
                let graph = RelationGraph.build(snapshot)
                let search = buildSearchIndex(snapshot)
                return (graph, search)
            }.value
            ...
                self.relationGraph = result.0
                self.searchIndex = result.1
```
doc comment 里的 "authors, annotations" 措辞同步改为 "relation graph"。

recomputeOpenDerived（:576-579）：
```swift
            openRelations = relations(for: e, in: entries,
                                      graph: relationGraph,
                                      topicMembership: topicMembership)
```

- [ ] **Step 4: 全量测试**

```bash
cd apple && swift test 2>&1 | tail -3
```
Expected: 全绿。若 `AppModelLoadIndexTests` 的关系断言（line 342/365 两个）失败，先检查是不是回退路径语义被改了——不许改测试迁就实现。

- [ ] **Step 5: Commit**

```bash
git add -A apple/Sources apple/Tests
git commit -m "refactor(catalog): relations() reads RelationGraph; drop author/annotation dicts (QUA-218)"
```

---

### Task 6: 规则② 容器 + siblingEntry 入 Kit

**Files:**
- Create: `apple/Sources/MarpleKit/Catalog/Containers.swift`
- Modify: `apple/Sources/MarpleKit/Catalog/BookContext.swift`、`TopicContext.swift`
- Modify: `apple/Sources/Marple/Inspector/InspectorMetadataRows.swift:235,246,253-257`
- Test: `apple/Tests/MarpleKitTests/ContainersTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
import Testing
@testable import MarpleKit

@Suite struct ContainersTests {
    // mk 工厂照抄 BookContextTests / TopicContextTests

    @Test func siblingEntryResolvesWithinDirectory() {
        let talk = mk(path: "vault/talks/t/talk.md", type: .talk)
        let transcript = mk(path: "vault/talks/t/transcript.md", type: .transcript)
        #expect(siblingEntry(of: talk, named: "transcript.md", in: [talk, transcript])?.path == transcript.path)
        #expect(siblingEntry(of: transcript, named: "talk.md", in: [talk, transcript])?.path == talk.path)
    }
    @Test func siblingEntryNilWhenMissing() {
        let talk = mk(path: "vault/talks/t/talk.md", type: .talk)
        #expect(siblingEntry(of: talk, named: "transcript.md", in: [talk]) == nil)
    }
    @Test func containerContextBookMatchesBookContext() {
        let overview = mk(path: "vault/books/b/00-overview.md", type: .book)
        let c1 = mk(path: "vault/books/b/01-x.md", type: .chapter)
        let entries = [c1, overview]
        let via = containerContext(for: c1, in: entries)
        #expect(via?.overview?.path == overview.path)
        #expect(via?.children.map(\.path) == [c1.path])
        #expect(bookContext(for: c1, in: entries)?.chapters.map(\.path) == via?.children.map(\.path))
    }
    @Test func containerContextTopicMatchesTopicContext() {
        let ov = mk(path: "vault/topics/t/00-overview.md", type: .topic, kind: "overview")
        let res = mk(path: "vault/topics/t/01-resources.md", type: .topic)
        let entries = [res, ov]
        let via = containerContext(for: res, in: entries)
        #expect(via?.overview?.path == ov.path)
        #expect(via?.children.map(\.path) == [res.path])
        #expect(topicContext(for: res, in: entries)?.pages.map(\.path) == via?.children.map(\.path))
    }
    @Test func containerContextNilForNonContainerTypes() {
        let paper = mk(path: "vault/papers/p.md", type: .paper)
        #expect(containerContext(for: paper, in: [paper]) == nil)
    }
}
```

- [ ] **Step 2: 确认失败，实现 Containers.swift**

```swift
import Foundation

// MARK: - 规则②：容器（同 <slug>/ 文件夹 = 同对象的目录式处理）
//
// 机制是通用的：slug 提取 → 同 slug 成员收集 → overview 判别 → 子页按路径排序。
// 语义差异保持有名字（QUA-218 公理 6）：
//   book  — overview 按类型判别（type=book），无章节也展示（空书可见）；
//   topic — overview 按 kind=overview 判别（路径首页兜底），单页不展示（噪音）；
//   talk  — 不走 slug 容器：talk.md↔transcript.md 是固定文件名配对，见 siblingEntry。
// BookContext / TopicContext 保持公开形状（视图零改动），构造改为本文件的投影。

/// 统一容器上下文：overview 锚点 + 有序子页。
public struct ContainerContext: Equatable, Sendable {
    public let slug: String
    public let overview: Entry?
    public let children: [Entry]   // ordered by path
    public init(slug: String, overview: Entry?, children: [Entry]) {
        self.slug = slug; self.overview = overview; self.children = children
    }
}

/// 规则②入口：entry 所属容器，或 nil。
public func containerContext(for entry: Entry, in entries: [Entry]) -> ContainerContext? {
    switch entry.type {
    case .book, .chapter:
        guard let c = bookContext(for: entry, in: entries) else { return nil }
        return ContainerContext(slug: c.slug, overview: c.overview, children: c.chapters)
    case .topic:
        guard let c = topicContext(for: entry, in: entries) else { return nil }
        return ContainerContext(slug: c.slug, overview: c.overview, children: c.pages)
    default:
        return nil
    }
}

/// folder-per-object 目录内的固定文件名配对（talk.md ↔ transcript.md）。
/// 搬自 Inspector（QUA-218 收拢进 Kit）；语义逐字保留。
public func siblingEntry(of entry: Entry, named filename: String, in entries: [Entry]) -> Entry? {
    let dir = (entry.path as NSString).deletingLastPathComponent
    let target = dir.isEmpty ? filename : dir + "/" + filename
    return entries.first { $0.path == target }
}
```

实现注意（与首版计划的差异）：`containerContext` 以 bookContext/topicContext 为实现而非反过来——两者的判别/空策略差异是**有意语义**（各自文件头注释已写明），共用的"slug+收集+排序"核心本来就只有几行；为消那几行重复而把判别规则参数化是造引擎。统一的价值在于：单一入口类型（PR3 Catalog / PR4 iOS 消费 ContainerContext）+ 三份手写收拢同档（Containers.swift 文件头是规则②的唯一叙述处）。

- [ ] **Step 3: Inspector 接线**

`InspectorMetadataRows.swift`：删私有 `siblingEntry`（:253-257）；:235 与 :246 的调用自动落到 MarpleKit 的公开同名函数（签名一致，编译即换）。`grep -n "private func siblingEntry" apple/Sources/Marple/` 确认删净。

- [ ] **Step 4: 全量测试**

```bash
cd apple && swift test 2>&1 | tail -3
```
Expected: 全绿（BookContextTests/TopicContextTests 一行不改）。

- [ ] **Step 5: Commit**

```bash
git add -A apple/Sources apple/Tests
git commit -m "feat(catalog): rule-2 container context + siblingEntry into Kit (QUA-218)"
```

---

### Task 7: 终验 + PR

**Files:** 无新改动；验证与交付。

- [ ] **Step 1: macOS 全量验证**

```bash
cd apple && swift build 2>&1 | grep -E "warning|error" | sort | uniq -c
cd apple && swift test 2>&1 | tail -3
```
Expected: 全绿；warning 集合不超出基线（VectorStore cblas_sgemv ×1、CollectionGridVariant MainActor ×2）。

- [ ] **Step 2: iOS 构建验证**

```bash
cd apple/ios && xcodegen generate
xcodebuild build -project MarpleiOS.xcodeproj -scheme MarpleiOS \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/marple-ios-dd CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```
Expected: `BUILD SUCCEEDED`。

- [ ] **Step 3: 安装 + GUI 抽查清单（交用户）**

```bash
cd apple && make install
```
清单（spec §7 关联面板全项）：① 打开一篇 paper：作者 chip 可跳作者页、"同作者作品/相似条目"面板与改前一致、期刊行链接正常；② 打开一章：本书面板（overview+章节列表）正常、书的批注在章上可见；③ 打开 topic 资源页：本专题面板 + 成员列表正常；④ talk↔transcript 互链正常；⑤ 正文 wikilink 点击跳转正常；⑥ 作者页"作品"列表正常。

- [ ] **Step 4: 开 PR**

```bash
git push -u origin qua-218-pr2
gh pr create --title "refactor(catalog): L2 relations — NameResolver + RelationGraph + rule engines (QUA-218, PR2/5)" --body "$(cat <<'EOF'
QUA-218 绞杀式迁移第 2 期（spec: docs/superpowers/specs/2026-06-11-qua-218-catalog-architecture-design.md）。

- Derivation/ 改名 Catalog/（L2 编目层落位；Catalog 类型本体 PR3 立起）
- NameResolver：四套名字匹配器归一为两级（第一级逐字保留旧算法，第二级共用宽松归一兜底）。
  用户预先批准的三条"只增不改"差异：作者页与 wikilink 解析获得变音符不敏感 + 空白折叠
  （旧命中 winner 一律不变；journal 匹配器本就是 folded 规则来源，逐字搬入无变化）
- RelationGraph：(from, kind, to, position?) 正反双向索引，规则①实体引用产出 authoredBy 边
  （含章→书 overview 锚点重映射的 annotates 边）；替代 authorIndex/annotationIndex 两张字典。
  topic 成员保留 TopicMembership（slug 键）、journal 链接保持按需查询——为守住"立即可见"
  时序，PR3 Catalog 接管惰性调度后再入图
- 规则②容器：ContainerContext 统一入口 + siblingEntry 配对规则入 Kit；
  BookContext/TopicContext 公开形状不变，视图零改动
- 七处胶水清账：authorIndex/annotationIndex/authorProfile ✔ 删并入图；journalEntry/siblingEntry ✔
  出壳入 Kit；BookContext/TopicContext ✔ 收拢规则②；speaker 列复用 ✔ PR1 已表驱动；
  ThemeIndex 关联部分 — 侦察确认只有 counts，无关联结构，无事可做

行为零变化（除上列三条批准差异）；swift test 全绿；iOS 构建通过。

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-Review 记录

- **Spec coverage**：§3.4 的 NameResolver/RelationGraph/规则①②/点名例外（annotationAnchor、PDF Jaccard 不动）各有任务；§6.2 的差异清单已获用户批准（2026-06-11 对话）。memberOf/publishedIn 边的延后与容器根目录不进 yaml 为计划级决策 4/7，PR body 注明。
- **Placeholder scan**：无 TBD。mk 工厂以"照抄某文件"指明，源文件路径明确。
- **Type consistency**：`NameResolver.authorPages/authorProfile/journalEntry/resolveWikilink`、`RelationGraph.build/targets(of:kind:)/sources(of:kind:)/worksByAuthorKey/empty/isEmpty`、`relations(for:in:graph:topicMembership:)`、`ContainerContext(slug:overview:children:)`、`siblingEntry(of:named:in:)` 各任务一致。
- **时序保真**：annotations 无回退（决策 6）、journal 按需查询（决策 4）、liveGraph isEmpty 回退对应旧 line 92——三处都有行内注释锚定。
