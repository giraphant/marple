# marple-native 架构地图

macOS 原生阅读器(纯 Swift)。数据层已完全脱离 Rust sidecar——索引在进程内用 Swift 构建、用 SQLite(GRDB)读写。本文件是目录结构的"地图",改动布局后请同步更新。

## 两个 target,单向依赖

SPM 包定义在 `Package.swift`,两个 target:

```
Marple (可执行, SwiftUI 外壳)  ──import──▶  MarpleKit (逻辑库, 无 UI)
```

- **MarpleKit**:领域模型 + 数据进出 + 索引器 + 派生计算 + markdown 渲染模型。不含任何 SwiftUI。
- **Marple**:只放 SwiftUI 视图 + `AppModel`(中枢 view-model)。所有逻辑都来自 MarpleKit。
- 依赖**严格单向**:UI 依赖逻辑,逻辑绝不反过来依赖 UI。

> Swift 机制提醒:同一个 target(module)内所有文件互相自动可见、无需 import;只有跨 target 才写 `import MarpleKit`。所以**子文件夹纯粹是给人看的组织,编译器不认**——SwiftPM 递归编译 `Sources/<target>/` 下所有 `.swift`。挪文件不会改任何 import,但也意味着"层级单向"是**君子协定,编译器不强制**。等哪天某条边界真需要强制(违规即编译报错),再把那块拆成独立 target。

## MarpleKit/ —— 按关注点分层

```
Sources/MarpleKit/
├── Model/         纯领域类型(最底层,人人可依赖)
│                  Entry · Frontmatter · TrashItem
├── Vault/         数据进出 + 关键协议缝
│                  VaultClient(协议 + StubVaultClient)· LocalVaultClient(纯 Swift 实现)
│                  IndexDatabase(读侧:查 SQLite)· VaultWatcher · VaultConfig
│                  FrontmatterPatch · NoteBuilder(写侧 helper)
├── Indexer/       写侧:扫库 → 建 SQLite 索引(从 rust/reader-core/indexer.rs 移植)
│                  VaultIndexer · IndexWriter · IndexedEntry · IndexFields
│                  IndexTitles · IndexBody · YamlFrontmatter · SourceResolver · GitDates
├── Catalog/       编目层（L2）：全部"由馆藏派生"的索引与关联（搜索、关系图、容器上下文、theme counts）。QUA-218 中由 `Derivation/` 改名；Catalog 类型本体在 PR3 立起。
│                  ThemeIndex · ListSort · ListFilter · Browse · CardMetrics
│                  RelationsIndex · DocStats · DocOutline
├── Markdown/      渲染模型
│                  MarkdownModel · Wikilink
├── Nav/           导航 + 状态持久化
│                  Navigation(Workspace/NavTab/NavHistory)· PersistedState
└── Schema/        Vault 词汇表:VaultSchema 声明表(实体字段别名、类型显示;可由 vault/schema/schema.yaml 覆盖)
                   + quasi 合规快照消费者(SchemaSnapshot · VaultConformance)
```

依赖方向:`Model/` 在最底;`Vault/`·`Indexer/`·`Catalog/`·`Markdown/`·`Nav/`·`Schema/` 只往下依赖 `Model/`,横向之间基本不互引(例外:`Schema/` 横向依赖 `Indexer/` 的 YAML 解析工具)。

## Marple/ —— 按功能竖切(feature folders)

```
Sources/Marple/
├── App/           应用外壳 + 中枢 view-model
│                  MarpleApp(@main + AppState.boot 组装点)· RootView(两轨外壳)
│                  AppModel(@Observable 中枢)· SetupView(首次选文库)
├── Sidebar/       左轨:6 类型 + 主题 + 回收站
│                  SidebarView
├── Browse/        中列:列表 / 卡片 / 主题 / 回收站 各 pane
│                  EntryListView · EntryRow(列表)
│                  EntryGridView(瀑布流外壳)· CollectionGridVariant(NSCollectionView)
│                  WaterfallCollectionLayout · EntryCardItem(纯 AppKit 卡片)· CardLayout · GridDimensions
│                  ThemesView · TrashView
├── Reading/       阅读视图
│                  DocView · MarkdownBlocksView
├── Inspector/     右轨:统计 / 信息 / 目录
│                  InspectorView
├── Tabs/          标签栏 + 快捷键
│                  TabStripView · TabCommands
└── Shared/        跨视图复用
                   Tokens(Space/Typo 设计 token)· FlowLayout(chip 流式布局)
```

## 关键缝:`VaultClient` 协议

`Vault/VaultClient.swift` 一个协议把"数据从哪来"抽象掉。`LocalVaultClient` 是当前实现(进程内文件 IO + 查 `IndexDatabase`);`StubVaultClient` 供测试。当年 sidecar→纯 Swift 的迁移之所以是 drop-in,就是因为只换了协议实现、`AppModel` 一行没改。**保留这个缝。**

## 数据流(开机到上屏)

```
VaultIndexer.reconcile()  →  写 <workspace>/.marple/index.sqlite (GRDB, WAL, 单写者)
        │
IndexDatabase             →  从该 SQLite 读 entries / 全文检索(trigram, CJK)
        │
LocalVaultClient          →  实现 VaultClient(读委派 IndexDatabase,写直接落文件)
        │
AppModel (@Observable)    →  编排:派生缓存(counts/themeIndex/visibleEntries)算在渲染路径之外,
        │                    大列表 filter→sort 甩到后台线程 + 取消旧任务
SwiftUI 视图               →  只读 AppModel 的 state
```

组装点只有一处:`App/MarpleApp.swift` 的 `AppState.boot`(reconcile → IndexDatabase → LocalVaultClient → AppModel → FSEvents watcher)。

## 还没做的

语义检索(BGE-M3 embedding)= Phase 3,目前 native 未使用,故 `Indexer/` 不含向量构建。届时新增的向量代码归入 `Indexer/`(写)+ `Vault/`(查)。
