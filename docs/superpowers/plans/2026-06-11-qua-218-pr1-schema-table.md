# QUA-218 PR1: L0 Schema 声明表 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 MarpleKit 立起 `Schema/` 声明表（实体字段别名、类型→图标/色），收拢 speaker/creator 列复用 hack 与 TypeIcon 硬编码，归并 Conformance 目录；内置默认 + `<workspaceRoot>/vault/schema/schema.yaml` 覆盖。**行为零变化**。

**Architecture:** 新增 `VaultSchema` 值类型（内置默认 `.builtin`，YAML 文件逐 key 覆盖）。索引器经 `buildIndexedEntry(schema:)` 参数消费别名表（`VaultIndexer` 在 init 自行加载，三个构造点零改动）；显示映射经 `@MainActor` 的 `VaultSchema.active` 供 SwiftUI 扩展读取。Conformance 两文件物理移入 `Schema/`，逻辑不动。容器约定**不在本 PR**（PR2 规则引擎落地时一并定形状，YAML 增量加 key 无破坏）。

**Tech Stack:** Swift 6 / SwiftPM。YAML 解析复用现有 `YamlFrontmatter.parseMapping`（Yams 包装，宽容降级）。测试 swift-testing/XCTest 跟随现有 `MarpleKitTests` 风格（动手前先看一眼 `apple/Tests/MarpleKitTests/IndexedEntryTests.swift` 用哪种，保持一致）。

**Worktree/分支:** 已在 `qua-218` 分支（worktree `…/qua-218`）。所有命令从仓库根执行；构建测试在 `apple/` 下。注意 `apple/.build` 是指向 `~/Library/Developer/marple-build` 的符号链接，勿删。

**关键现状（执行者需知）:**
- `EntryType`：`apple/Sources/MarpleKit/Model/Entry.swift:3` 起，10 个具名 case + `.other(String)`，`rawValue: String`。
- speaker/creator hack：`apple/Sources/MarpleKit/Indexer/IndexedEntry.swift:339-348`，**类型限定**（speaker 仅 talk、creator 仅 image），回退顺序 author → authors → speaker → creator。
- 图标/色硬编码：`apple/Sources/Marple/Shared/TypeIcon.swift`（macOS app 层，iOS 用不到）。`symbolName` 调用点：`SettingsView.swift:98`、`SidebarTabOutlineView.swift:406`；`TypeBadge` 调用点：`SidebarTabOutlineView.swift:1789`、`CommandPalette.swift:258,273`。
- Conformance：`apple/Sources/MarpleKit/Conformance/{SchemaSnapshot,VaultConformance}.swift`，已是 quasi 快照（`.quasi/schema.json`）的数据消费者，本 PR 只移动不改逻辑。
- `VaultIndexer.init(workspaceRoot:indexDBPath:)`：`VaultIndexer.swift:61`；`buildIndexedEntry` 调用点在 `VaultIndexer.swift:97`（buildFull）与 `:465`（reconcile 路径）。
- `buildIndexedEntry` 签名：`IndexedEntry.swift:268`，free function，参数尾部有 `sourceIndex: SourceSlugIndex? = nil`。

---

### Task 1: VaultSchema 类型 + 内置默认

**Files:**
- Create: `apple/Sources/MarpleKit/Schema/VaultSchema.swift`
- Test: `apple/Tests/MarpleKitTests/VaultSchemaTests.swift`

- [ ] **Step 1: 写失败测试**

新建 `apple/Tests/MarpleKitTests/VaultSchemaTests.swift`（若现有测试用 XCTest 则照写 XCTest；下面以 XCTest 为例）：

```swift
import XCTest
@testable import MarpleKit

final class VaultSchemaTests: XCTestCase {

    // 内置别名表必须逐字复刻 IndexedEntry.swift:343-348 的现状回退链
    func testBuiltinAuthorAliases() {
        let aliases = VaultSchema.builtin.entityAliases["author"]
        XCTAssertEqual(aliases, [
            VaultSchema.FieldAlias("author"),
            VaultSchema.FieldAlias("authors"),
            VaultSchema.FieldAlias("speaker", onlyForType: "talk"),
            VaultSchema.FieldAlias("creator", onlyForType: "image"),
        ])
    }

    func testBuiltinJournalAndTopicAliases() {
        XCTAssertEqual(VaultSchema.builtin.entityAliases["journal"],
                       [VaultSchema.FieldAlias("journal")])
        XCTAssertEqual(VaultSchema.builtin.entityAliases["topic"],
                       [VaultSchema.FieldAlias("topics")])
    }

    // 内置显示表必须逐字复刻 Marple/Shared/TypeIcon.swift 的现状 switch
    func testBuiltinDisplayMatchesLegacyTypeIcon() {
        let expected: [(EntryType, String, String)] = [
            (.paper,      "doc.text",                 "blue"),
            (.book,       "book",                     "orange"),
            (.author,     "person",                   "purple"),
            (.topic,      "square.stack.3d.up",       "teal"),
            (.journal,    "newspaper",                "green"),
            (.chapter,    "list.bullet.rectangle",    "indigo"),
            (.note,       "note.text",                "yellow"),
            (.image,      "photo",                    "pink"),
            (.talk,       "waveform",                 "red"),
            (.transcript, "text.quote",               "brown"),
            (.other("x"), "questionmark.square.dashed", "gray"),
        ]
        for (type, symbol, tint) in expected {
            let d = VaultSchema.builtin.display(for: type)
            XCTAssertEqual(d.symbol, symbol, "\(type)")
            XCTAssertEqual(d.tint, tint, "\(type)")
        }
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```
cd apple && swift test --filter VaultSchemaTests 2>&1 | tail -20
```
Expected: 编译失败 `cannot find 'VaultSchema' in scope`。

- [ ] **Step 3: 最小实现**

新建 `apple/Sources/MarpleKit/Schema/VaultSchema.swift`：

```swift
import Foundation

/// The vault's vocabulary as data — which frontmatter fields reference which
/// entity type, and how each entry type is displayed. Built-in defaults mirror
/// what used to be hard-coded across the indexer (speaker/creator column
/// reuse) and the macOS app (TypeIcon). A `vault/schema/schema.yaml` next to
/// the indexed content can override individual keys; see `load(workspaceRoot:)`.
///
/// This is deliberately a *table*, not an engine: semantics live in named
/// Swift code (rules, resolvers); this type only declares the vocabulary.
public struct VaultSchema: Sendable, Equatable {

    /// One frontmatter field that references an entity type, optionally
    /// restricted to entries of a single type (e.g. `speaker` only on `talk`).
    public struct FieldAlias: Sendable, Equatable {
        public let field: String
        public let onlyForType: String?

        public init(_ field: String, onlyForType: String? = nil) {
            self.field = field
            self.onlyForType = onlyForType
        }
    }

    /// SF Symbol name + platform-agnostic tint name for one entry type.
    /// Tint names are mapped to concrete colors by each UI shell.
    public struct TypeDisplay: Sendable, Equatable {
        public let symbol: String
        public let tint: String

        public init(symbol: String, tint: String) {
            self.symbol = symbol
            self.tint = tint
        }
    }

    /// Entity type → ordered list of frontmatter fields that reference it.
    /// Order matters: first present field wins (mirrors the legacy fallback
    /// chain `author ?? authors ?? speaker ?? creator`).
    public var entityAliases: [String: [FieldAlias]]

    /// EntryType rawValue → display. Unknown types fall back to `fallbackDisplay`.
    public var displayByType: [String: TypeDisplay]

    /// Display for `.other` / undeclared types.
    public var fallbackDisplay: TypeDisplay

    public func display(for type: EntryType) -> TypeDisplay {
        displayByType[type.rawValue] ?? fallbackDisplay
    }

    public static let builtin = VaultSchema(
        entityAliases: [
            "author": [
                FieldAlias("author"),
                FieldAlias("authors"),
                FieldAlias("speaker", onlyForType: "talk"),
                FieldAlias("creator", onlyForType: "image"),
            ],
            "journal": [FieldAlias("journal")],
            "topic": [FieldAlias("topics")],
        ],
        displayByType: [
            "paper":      TypeDisplay(symbol: "doc.text", tint: "blue"),
            "book":       TypeDisplay(symbol: "book", tint: "orange"),
            "author":     TypeDisplay(symbol: "person", tint: "purple"),
            "topic":      TypeDisplay(symbol: "square.stack.3d.up", tint: "teal"),
            "journal":    TypeDisplay(symbol: "newspaper", tint: "green"),
            "chapter":    TypeDisplay(symbol: "list.bullet.rectangle", tint: "indigo"),
            "note":       TypeDisplay(symbol: "note.text", tint: "yellow"),
            "image":      TypeDisplay(symbol: "photo", tint: "pink"),
            "talk":       TypeDisplay(symbol: "waveform", tint: "red"),
            "transcript": TypeDisplay(symbol: "text.quote", tint: "brown"),
        ],
        fallbackDisplay: TypeDisplay(symbol: "questionmark.square.dashed", tint: "gray")
    )
}
```

注意：`.other("x").rawValue` 是 `"x"`，不在 `displayByType` → 走 fallback，正好等价旧 switch 的 `.other` 分支。

- [ ] **Step 4: 跑测试确认通过**

```
cd apple && swift test --filter VaultSchemaTests 2>&1 | tail -5
```
Expected: 3 tests PASS。

- [ ] **Step 5: Commit**

```bash
git add apple/Sources/MarpleKit/Schema/VaultSchema.swift apple/Tests/MarpleKitTests/VaultSchemaTests.swift
git commit -m "feat(schema): VaultSchema declaration table with builtin vocabulary (QUA-218)"
```

---

### Task 2: schema.yaml 覆盖加载

**Files:**
- Modify: `apple/Sources/MarpleKit/Schema/VaultSchema.swift`
- Test: `apple/Tests/MarpleKitTests/VaultSchemaTests.swift`

- [ ] **Step 1: 写失败测试**

追加到 `VaultSchemaTests.swift`（类内）：

```swift
    private func makeWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("vault/schema"),
            withIntermediateDirectories: true)
        return root
    }

    func testLoadWithoutFileReturnsBuiltin() throws {
        let root = try makeWorkspace()
        XCTAssertEqual(VaultSchema.load(workspaceRoot: root.path), .builtin)
    }

    func testLoadAppliesPerKeyOverrides() throws {
        let root = try makeWorkspace()
        let yaml = """
        entities:
          author:
            fields:
              - author
              - field: translator
                type: book
        display:
          paper:
            symbol: doc.richtext
            tint: mint
        """
        try yaml.write(to: root.appendingPathComponent("vault/schema/schema.yaml"),
                       atomically: true, encoding: .utf8)
        let schema = VaultSchema.load(workspaceRoot: root.path)
        // author 整 key 替换
        XCTAssertEqual(schema.entityAliases["author"], [
            VaultSchema.FieldAlias("author"),
            VaultSchema.FieldAlias("translator", onlyForType: "book"),
        ])
        // 未提及的 key 保持内置
        XCTAssertEqual(schema.entityAliases["journal"], VaultSchema.builtin.entityAliases["journal"])
        XCTAssertEqual(schema.display(for: .paper),
                       VaultSchema.TypeDisplay(symbol: "doc.richtext", tint: "mint"))
        XCTAssertEqual(schema.display(for: .book), VaultSchema.builtin.display(for: .book))
    }

    func testLoadMalformedFileReturnsBuiltin() throws {
        let root = try makeWorkspace()
        try "][ not yaml ][".write(to: root.appendingPathComponent("vault/schema/schema.yaml"),
                                   atomically: true, encoding: .utf8)
        XCTAssertEqual(VaultSchema.load(workspaceRoot: root.path), .builtin)
    }
```

- [ ] **Step 2: 跑测试确认失败**

```
cd apple && swift test --filter VaultSchemaTests 2>&1 | tail -10
```
Expected: 编译失败 `type 'VaultSchema' has no member 'load'`。

- [ ] **Step 3: 实现 load**

追加到 `VaultSchema.swift`（struct 体外，文件尾部）：

```swift
public extension VaultSchema {

    /// Schema override location relative to the workspace root. Lives inside
    /// `vault/schema/` (the user's synced data, shared territory with quasi;
    /// the vault root keeps no loose files) — NOT `.marple/`, which is a
    /// disposable cache rebuilt via `rm -rf`.
    static let relativePath = "vault/schema/schema.yaml"

    /// Built-in defaults overlaid by `vault/schema/schema.yaml` when present.
    ///
    /// Override granularity is per top-level entity / display key: declaring
    /// `entities.author` replaces the author alias list wholesale; keys not
    /// mentioned keep their builtin value. Malformed YAML or unreadable file
    /// → builtin (graceful degradation, same philosophy as SchemaSnapshot).
    static func load(workspaceRoot: String) -> VaultSchema {
        guard !workspaceRoot.isEmpty else { return .builtin }
        let url = URL(fileURLWithPath: workspaceRoot).appendingPathComponent(relativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .builtin }
        return builtin.applying(overrides: YamlFrontmatter.parseMapping(text))
    }

    /// Apply a parsed YAML mapping onto self. Unrecognized or ill-typed keys
    /// are ignored (keep builtin) rather than failing the whole file.
    func applying(overrides: [(String, YamlValue)]) -> VaultSchema {
        var result = self
        for (key, value) in overrides {
            switch key {
            case "entities":
                guard case .mapping(let entities) = value else { continue }
                for (entity, spec) in entities {
                    guard case .mapping(let fields) = spec,
                          let fieldsValue = fields.first(where: { $0.0 == "fields" })?.1,
                          case .sequence(let items) = fieldsValue else { continue }
                    let aliases = items.compactMap { Self.alias(from: $0) }
                    if !aliases.isEmpty { result.entityAliases[entity] = aliases }
                }
            case "display":
                guard case .mapping(let types) = value else { continue }
                for (type, spec) in types {
                    guard case .mapping(let pairs) = spec,
                          case .string(let symbol)? = pairs.first(where: { $0.0 == "symbol" })?.1,
                          case .string(let tint)? = pairs.first(where: { $0.0 == "tint" })?.1
                    else { continue }
                    result.displayByType[type] = TypeDisplay(symbol: symbol, tint: tint)
                }
            default:
                continue
            }
        }
        return result
    }

    /// A fields item is either a plain string (`- author`) or a mapping
    /// (`- {field: speaker, type: talk}`).
    private static func alias(from value: YamlValue) -> FieldAlias? {
        switch value {
        case .string(let s):
            return FieldAlias(s)
        case .mapping(let pairs):
            guard case .string(let f)? = pairs.first(where: { $0.0 == "field" })?.1 else { return nil }
            if case .string(let t)? = pairs.first(where: { $0.0 == "type" })?.1 {
                return FieldAlias(f, onlyForType: t)
            }
            return FieldAlias(f)
        default:
            return nil
        }
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

```
cd apple && swift test --filter VaultSchemaTests 2>&1 | tail -5
```
Expected: 6 tests PASS。

- [ ] **Step 5: Commit**

```bash
git add apple/Sources/MarpleKit/Schema/VaultSchema.swift apple/Tests/MarpleKitTests/VaultSchemaTests.swift
git commit -m "feat(schema): vault/schema/schema.yaml per-key overrides with graceful degradation (QUA-218)"
```

---

### Task 3: 索引器消费别名表（替换 speaker/creator hack）

**Files:**
- Modify: `apple/Sources/MarpleKit/Indexer/IndexedEntry.swift:268-348`
- Modify: `apple/Sources/MarpleKit/Indexer/VaultIndexer.swift:32-70,97,465`
- Test: `apple/Tests/MarpleKitTests/VaultSchemaTests.swift`

- [ ] **Step 1: 写失败测试**

追加到 `VaultSchemaTests.swift`。先看 `apple/Tests/MarpleKitTests/IndexedEntryTests.swift` 顶部现有 helper 怎么构造 `buildIndexedEntry` 输入（text/rel/fileStem/sourceSlugs），保持同风格；下面是独立写法：

```swift
    func testIndexerUsesSchemaAuthorAliases() {
        let text = """
        ---
        type: book
        title: T
        translator: 张三
        ---
        body
        """
        var schema = VaultSchema.builtin
        schema.entityAliases["author"] = [
            VaultSchema.FieldAlias("author"),
            VaultSchema.FieldAlias("translator", onlyForType: "book"),
        ]
        let outcome = buildIndexedEntry(
            text: text, rel: "vault/books/t/book.md", fileStem: "book",
            sourceSlugs: [], mtimeMs: nil, schema: schema)
        guard case .indexed(let entry) = outcome else {
            return XCTFail("expected .indexed, got \(outcome)")
        }
        XCTAssertEqual(entry.author, ["张三"])
    }

    // 默认 schema 下既有行为不变：talk 的 speaker 落 author 列
    func testIndexerDefaultSchemaKeepsTalkSpeakerFold() {
        let text = """
        ---
        type: talk
        title: T
        speaker: 李四
        ---
        body
        """
        let outcome = buildIndexedEntry(
            text: text, rel: "vault/talks/t/talk.md", fileStem: "talk",
            sourceSlugs: [], mtimeMs: nil)
        guard case .indexed(let entry) = outcome else {
            return XCTFail("expected .indexed, got \(outcome)")
        }
        XCTAssertEqual(entry.author, ["李四"])
    }

    // 类型限定生效：speaker 在非 talk 类型上不折入 author
    func testIndexerAliasTypeRestriction() {
        let text = """
        ---
        type: note
        title: T
        speaker: 王五
        ---
        body
        """
        let outcome = buildIndexedEntry(
            text: text, rel: "vault/notes/n.md", fileStem: "n",
            sourceSlugs: [], mtimeMs: nil)
        guard case .indexed(let entry) = outcome else {
            return XCTFail("expected .indexed, got \(outcome)")
        }
        XCTAssertEqual(entry.author, [])
    }
```

注意：`BuildOutcome` 的 case 名以 `IndexedEntry.swift` 实际定义为准（执行时先 grep `enum BuildOutcome`，若 case 名不是 `.indexed(let entry)` 则按实际改测试）。

- [ ] **Step 2: 跑测试确认失败**

```
cd apple && swift test --filter VaultSchemaTests 2>&1 | tail -10
```
Expected: 编译失败 `extra argument 'schema' in call`。

- [ ] **Step 3: 实现**

3a. `IndexedEntry.swift:268` — `buildIndexedEntry` 签名加尾参（带默认值，既有调用点不破坏）：

```swift
public func buildIndexedEntry(
    text: String,
    rel: String,
    fileStem: String,
    sourceSlugs: Set<String>,
    mtimeMs: Int64?,
    sourceIndex: SourceSlugIndex? = nil,
    schema: VaultSchema = .builtin
) -> BuildOutcome {
```

3b. `IndexedEntry.swift:339-348` — 删除硬编码回退链，替换为：

```swift
    // 8. Themes, topics, author.
    let themesValue: [String]? = themeArray(field(frontmatter, "themes"))
    let topicsValue: [String]? = themeArray(field(frontmatter, "topics"))
    // Entity-reference aliases come from the schema table (builtin mirrors the
    // old hard-coded chain: author → authors → speaker(talk) → creator(image)).
    let authorValue: [String] = parseAuthors(
        entityFieldValue(frontmatter, entity: "author", entryType: entryType, schema: schema)
    )
```

3c. 同文件追加 helper（放在 `buildIndexedEntry` 之后、其它 fileprivate helper 旁）：

```swift
/// First present frontmatter value among the schema's alias fields for the
/// given entity type, honoring per-type restrictions. Order = declaration order.
private func entityFieldValue(
    _ frontmatter: [(String, YamlValue)],
    entity: String,
    entryType: String,
    schema: VaultSchema
) -> YamlValue? {
    for alias in schema.entityAliases[entity] ?? [] {
        guard alias.onlyForType == nil || alias.onlyForType == entryType else { continue }
        if let v = field(frontmatter, alias.field) { return v }
    }
    return nil
}
```

注意 `field(_:_:)` 与 `entryType`（String 局部变量）已在该文件作用域内存在，直接用。

3d. `VaultIndexer.swift` — init 加载 schema 并在两个调用点传入：

```swift
    /// Vocabulary table loaded once per indexer instance (builtin + optional
    /// vault/schema/schema.yaml override). Immutable thereafter — a schema edit needs
    /// an app relaunch, same as today's rebuild semantics.
    private let schema: VaultSchema
```

init 内（`self.sourcesPath = ...` 之后）：

```swift
        self.schema = VaultSchema.load(workspaceRoot: workspaceRoot)
```

`:97` 与 `:465` 两处 `buildIndexedEntry(` 调用各加实参 `schema: schema`（保持其余实参不动）。

- [ ] **Step 4: 跑全量测试**

```
cd apple && swift test 2>&1 | tail -5
```
Expected: 全绿（既有 talk/image 折叠行为由内置表逐字复刻，QUA-183 相关测试不应变红；若变红即为等价性回归，必须查明而不是改测试）。

- [ ] **Step 5: Commit**

```bash
git add apple/Sources/MarpleKit/Indexer/IndexedEntry.swift apple/Sources/MarpleKit/Indexer/VaultIndexer.swift apple/Tests/MarpleKitTests/VaultSchemaTests.swift
git commit -m "refactor(indexer): author field aliases from schema table, drop speaker/creator hardcode (QUA-218)"
```

---

### Task 4: 显示映射入 Kit，TypeIcon 瘦成壳层适配

**Files:**
- Create: `apple/Sources/MarpleKit/Schema/EntryTypeDisplay.swift`
- Modify: `apple/Sources/Marple/Shared/TypeIcon.swift`
- Modify: `apple/Sources/Marple/App/AppModel.swift:844` 附近
- Test: `apple/Tests/MarpleKitTests/VaultSchemaTests.swift`

- [ ] **Step 1: 写失败测试**

追加到 `VaultSchemaTests.swift`：

```swift
    @MainActor
    func testEntryTypeDisplayReadsActiveSchema() {
        defer { VaultSchema.active = .builtin }   // 不污染其它测试
        XCTAssertEqual(EntryType.paper.symbolName, "doc.text")
        XCTAssertEqual(EntryType.paper.tintName, "blue")
        var custom = VaultSchema.builtin
        custom.displayByType["paper"] = .init(symbol: "doc.richtext", tint: "mint")
        VaultSchema.active = custom
        XCTAssertEqual(EntryType.paper.symbolName, "doc.richtext")
        XCTAssertEqual(EntryType.paper.tintName, "mint")
    }
```

- [ ] **Step 2: 跑测试确认失败**

```
cd apple && swift test --filter VaultSchemaTests 2>&1 | tail -10
```
Expected: 编译失败 `has no member 'active'` / `'symbolName'`。

- [ ] **Step 3: 实现 Kit 侧**

新建 `apple/Sources/MarpleKit/Schema/EntryTypeDisplay.swift`：

```swift
import Foundation

public extension VaultSchema {
    /// The schema in effect for display lookups. Set once by the app shell
    /// when a vault opens (AppModel.loadIndex); defaults to builtin so views
    /// render sensibly before any vault is open. Main-actor because every
    /// consumer is a view; the indexer carries its own copy instead.
    @MainActor static var active: VaultSchema = .builtin
}

/// Display attributes for entry types, read from the active schema.
/// Platform-agnostic strings — each UI shell maps `tintName` to a color.
@MainActor
public extension EntryType {
    var symbolName: String { VaultSchema.active.display(for: self).symbol }
    var tintName: String { VaultSchema.active.display(for: self).tint }
}
```

- [ ] **Step 4: 改写 macOS 壳层 TypeIcon.swift**

`apple/Sources/Marple/Shared/TypeIcon.swift` 整体替换为（`TypeBadge` 本体不变，删除两个硬编码 switch，新增 tint 名→Color 映射）：

```swift
import SwiftUI
import MarpleKit

/// Capacities-style typed icon (mirrors the web `TypeIcon`): a small rounded
/// tinted square holding the type's SF Symbol. Symbol + tint names come from
/// the schema declaration table (VaultSchema.active); this file only maps the
/// platform-agnostic tint name onto a SwiftUI Color.
extension EntryType {
    var tint: Color {
        switch tintName {
        case "blue":   return .blue
        case "orange": return .orange
        case "purple": return .purple
        case "teal":   return .teal
        case "green":  return .green
        case "indigo": return .indigo
        case "yellow": return .yellow
        case "pink":   return .pink
        case "red":    return .red
        case "brown":  return .brown
        case "mint":   return .mint
        case "cyan":   return .cyan
        default:       return .gray
        }
    }
}

struct TypeBadge: View {
    let type: EntryType
    var size: CGFloat = 18

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(type.tint.opacity(0.18))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: type.symbolName)
                    .font(.system(size: size * 0.56, weight: .semibold))
                    .foregroundStyle(type.tint)
            )
    }
}
```

- [ ] **Step 5: AppModel 在 vault 打开时设 active**

`apple/Sources/Marple/App/AppModel.swift:844`（`schemaSnapshot = SchemaSnapshot.load(...)` 那行）后紧跟：

```swift
        VaultSchema.active = VaultSchema.load(workspaceRoot: workspaceRoot)
```

（loadIndex 已在 main actor 上下文；若编译器在此处要求 `await MainActor.run`，按其要求包裹。）

- [ ] **Step 6: 全量构建+测试**

```
cd apple && swift build 2>&1 | grep -c warning; swift test 2>&1 | tail -5
```
Expected: 测试全绿。warning 数不高于基线（基线 = 主分支的 3 处：VectorStore CBLAS ×1、CollectionGridVariant MainActor ×2；合并 QUA-175 后先跑一次主干基线再比对）。若 `symbolName` 的 `@MainActor` 在 `SidebarTabOutlineView.swift:406` 或 `SettingsView.swift:98` 引发隔离报错，把报错处所在函数标注 `@MainActor`（这两处本就跑在主线程）。

- [ ] **Step 7: Commit**

```bash
git add apple/Sources/MarpleKit/Schema/EntryTypeDisplay.swift apple/Sources/Marple/Shared/TypeIcon.swift apple/Sources/Marple/App/AppModel.swift apple/Tests/MarpleKitTests/VaultSchemaTests.swift
git commit -m "refactor(schema): type icon/tint mapping moves to declaration table (QUA-218)"
```

---

### Task 5: Conformance 归并入 Schema/

**Files:**
- Move: `apple/Sources/MarpleKit/Conformance/SchemaSnapshot.swift` → `apple/Sources/MarpleKit/Schema/SchemaSnapshot.swift`
- Move: `apple/Sources/MarpleKit/Conformance/VaultConformance.swift` → `apple/Sources/MarpleKit/Schema/VaultConformance.swift`
- Modify: `apple/ARCHITECTURE.md`

- [ ] **Step 1: git mv（零逻辑改动）**

```bash
git mv apple/Sources/MarpleKit/Conformance/SchemaSnapshot.swift apple/Sources/MarpleKit/Schema/
git mv apple/Sources/MarpleKit/Conformance/VaultConformance.swift apple/Sources/MarpleKit/Schema/
rmdir apple/Sources/MarpleKit/Conformance 2>/dev/null || true
```

- [ ] **Step 2: 更新 ARCHITECTURE.md**

```
grep -n "Conformance" apple/ARCHITECTURE.md
```
把提及 `Conformance/` 的条目改为 `Schema/`，并在该节补一句目录说明（措辞示例）：
> `Schema/` — the vault's vocabulary as data: `VaultSchema` declaration table (entity field aliases, type display; overridable via `vault/schema/schema.yaml`) plus the quasi conformance snapshot consumers (`SchemaSnapshot`, `VaultConformance`).

- [ ] **Step 3: 全量测试**

```
cd apple && swift test 2>&1 | tail -3
```
Expected: 全绿（SPM 按 target 整目录编译，移动无需配置变更）。

- [ ] **Step 4: Commit**

```bash
git add -A apple/Sources/MarpleKit apple/ARCHITECTURE.md
git commit -m "refactor(schema): fold Conformance/ into Schema/ (QUA-218)"
```

---

### Task 6: 终验 + PR

**Files:** 无新改动；验证与交付。

- [ ] **Step 1: macOS 全量验证**

```
cd apple && swift build 2>&1 | grep -E "warning|error" | sort | uniq -c
cd apple && swift test 2>&1 | tail -3
```
Expected: 测试全绿；warning 集合与主干基线一致（不新增）。

- [ ] **Step 2: iOS 构建验证（MarpleKit 被 iOS 复用，必须验证）**

```
cd apple/ios && xcodegen generate
xcodebuild build -project MarpleiOS.xcodeproj -scheme MarpleiOS \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/marple-ios-dd CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```
Expected: `BUILD SUCCEEDED`。（`EntryTypeDisplay` 的 `@MainActor` 静态量在 iOS 侧无消费者，仅需编译通过。）

- [ ] **Step 3: 行为零变化的 GUI 抽查（交给用户，附清单）**

```
cd apple && make install
```
然后请用户确认：① 侧边栏/命令面板的类型图标和颜色与之前一致；② 任一 talk 条目的讲者仍显示在作者位；③ 任一 image 条目的创作者仍显示在作者位。

- [ ] **Step 4: 开 PR**

```bash
git push -u origin qua-218
gh pr create --title "refactor(schema): L0 declaration table — vocabulary as data (QUA-218, PR1/5)" --body "$(cat <<'EOF'
QUA-218 绞杀式迁移第 1 期（spec: docs/superpowers/specs/2026-06-11-qua-218-catalog-architecture-design.md）。

- 新增 MarpleKit/Schema/VaultSchema：实体字段别名 + 类型→图标/色 的声明表；
  内置默认逐字复刻旧硬编码，vault/schema/schema.yaml 可逐 key 覆盖（缺失/损坏时优雅回退）
- 索引器 author 折叠改读别名表（speaker→talk、creator→image 的硬编码删除）
- TypeIcon 的 symbol/tint 硬编码下沉声明表，macOS 壳只剩 tint 名→Color 映射
- Conformance/ 物理归并入 Schema/（quasi 快照消费逻辑零改动）

行为零变化；swift test 全绿；iOS 构建通过。

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-Review 记录

- **Spec coverage**：spec §3.3 的"实体别名/显示/校验"三项均有任务（T1-T5）；"容器约定"显式延至 PR2（计划头已记录理由，与 spec §6 PR1 句一致）。schema.yaml 位置与 spec 一致（vault/schema/ 目录、vault 根不放散文件、避开 .marple/）。
- **Placeholder scan**：无 TBD；Task 3 Step 1 对 `BuildOutcome` case 名留了执行时核对指引（grep 后按实际调整），属事实核对而非占位。
- **Type consistency**：`FieldAlias(_:onlyForType:)`、`TypeDisplay(symbol:tint:)`、`display(for:)`、`VaultSchema.active`、`entityFieldValue(_:entity:entryType:schema:)` 各任务间签名一致；`buildIndexedEntry` 新尾参 `schema: VaultSchema = .builtin` 与 Task 3 测试调用一致。
