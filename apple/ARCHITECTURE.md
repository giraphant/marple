# marple-native 架构地图

一颗 **MarpleKit** 核 + 两层薄壳,覆盖一座 markdown 学术文库(vault)。核里是领域模型 + 数据进出 + 索引 + 派生编目 + markdown 渲染 + 会话/导航,全程纯 Swift、无 SwiftUI;两层壳只放各自平台的 UI 与边界胶水:**Marple**(macOS,可读写)与 **MarpleiOS**(iPhone,只读 reader)。两壳消费同一颗核。本文件是目录结构的"地图",改动布局后请同步更新。

## 分层模型(L0→L4)

数据在核里自下而上流过五层,每层只往下依赖:

- **L0 Schema** —— 文库词汇表声明:实体字段别名、type→图标/配色、容器语义。一切派生的语义起点。
- **L1 Vault** —— 数据进出 + 关键协议缝:`VaultClient`(数据从哪来)、`IndexDatabase`(读 SQLite)、`VaultChangeSource`(变更通知契约)、写侧 primitive、Superset 自动化、语义检索后端。
- **L2 Catalog** —— 编目层:全部"由馆藏派生"的状态(counts/themeIndex/搜索/关系图/容器上下文),统一 generation/单飞权威。唯一派生 owner。
- **L3 Markdown** —— 文档渲染模型:markdown→行模型→`AttributedString`、wikilink、表格附件、talk 时间线。
- **L4 Session/Nav** —— 会话/导航:工作区/标签/历史/持久化状态(Nav)、会话快照落盘 + 元数据写回(Session)。

## 三棵树

### MarpleKit/ —— 核(纯逻辑,无 UI),按关注点分层

```
Sources/MarpleKit/
├── Model/         L0 之下:纯领域类型(最底,人人可依赖)
│                  Entry(含 EntryType)· Frontmatter · ImageAsset · TrashItem
├── Schema/        L0:文库词汇表
│                  VaultSchema(声明表;可由 vault/schema/schema.yaml 覆盖)· EntryTypeDisplay
│                  + quasi 合规快照消费者(SchemaSnapshot · VaultConformance)
├── Vault/         L1:数据进出 + 协议缝
│                  VaultClient(协议 + StubVaultClient)· LocalVaultClient(纯 Swift 实现)
│                  IndexDatabase(读侧:查 SQLite)· VaultConfig/VaultPaths
│                  VaultChangeSource(变更契约)· VaultWatcher(Mac FSEvents 实现)
│                  FrontmatterPatch · NoteBuilder(写侧 helper)
│                  SemanticSearcher · SemanticBackend · VectorStore(语义检索查侧)
│                  TalkMedia/SRT(transcript 媒体)
│                  Superset{Log,Runner,Automation}(外部 agent 派发 + 上下文打包)
├── Indexer/       写侧:扫库 → 建 SQLite 索引(从 rust/reader-core 移植)
│                  VaultIndexer · IndexWriter · IndexedEntry · IndexFields
│                  IndexTitles · IndexBody · YamlFrontmatter · GitDates
│                  SourceResolver(PDF 源解析,含 Jaccard 模糊匹配)· ImageProbe
│                  SemanticIndexer · TextEmbedder · HFTokenizer(语义写侧)
├── Catalog/       L2:派生编目层(唯一派生 owner)。"图书馆目录"隐喻:从馆藏派生、可重编、多路检索、带交叉引用。
│                  Catalog(@Observable 派生状态本体)
│                  Catalog+IndexDerived/+DeferredDerived/+Visible/+OpenDoc/+Refresh(按关注点拆的重算扩展)
│                  RefreshAuthority(actor:统一 generation/单飞)· RefreshAuthority 之上的 pass + 独立 derivedGeneration 轴
│                  NameResolver(规则①解析端:统一两级名字归一)· RelationGraph · RelationsIndex(annotationAnchor 章→书 remap 例外)
│                  Containers(规则②:同 slug 容器)· BookContext · TopicContext · TopicIndex · ThemeIndex
│                  SearchRanker · CommandSearch · SearchIndex · BodyMatching/BodyLineMatches · Citation
│                  ListSort · ListFilter · SavedView · Browse · CardMetrics · DocStats · DocOutline
├── Markdown/      L3:渲染模型
│                  MarkdownModel · MarkdownLine · AttributedStringRenderer
│                  Wikilink · TableAttachment · TalkTimeline · Platform
├── Nav/           L4:导航 + 状态持久化
│                  Navigation(Workspace/NavTab/NavHistory/Group/TabGroup)· PersistedState
│                  SessionSnapshot · TabShareManifest · StateStore(协议)/UserDefaultsStateStore
├── Session/       L4:会话落盘 + 元数据写回(写侧 primitive)
│                  SessionWriter(<vaultRoot>/session/*.json)· MetadataWriter · SessionResolver
├── Localisation/  本地化辅助:CnDoubanIndex(中文豆瓣索引)
├── CLI/           CLI 协议类型(壳侧 socket host 用):CLIProtocol(请求/响应/方法/错误码)
└── Backup/        备份引擎:CloneCopy · SnapshotStore · RetentionPolicy(UI/调度在壳)
```

### Marple/ —— macOS 壳(SwiftUI + AppKit,可读写),按功能竖切

```
Sources/Marple/
├── App/           应用外壳 + 中枢 view-model + 窗口
│                  MarpleApp(@main + 组装点)· AppModel(@Observable 中枢)· SetupView(首次选文库)
│                  MarpleWindowController · MarpleSplitViewController(AppKit split 外壳)
│                  MainToolbar · CommandPalettePanel · MemoryWatchdog
├── Sidebar/       左轨:类型 + 主题 + 回收站
│                  SidebarView · SidebarTabOutlineView
├── Browse/        中列:列表 / 表格 / 卡片 / 主题 / 回收站
│                  EntryListView · EntryListTable · EntryRow · EntryGridView · CollectionGridVariant
│                  WaterfallCollectionLayout · EntryCardItem(纯 AppKit)· CardLayout · GridDimensions
│                  CommandPalette · ThemesView · TrashView
├── Reading/       阅读视图
│                  DocView · MarkdownTextView(TextKit 2)· TalkPlayerView
├── Inspector/     右轨:统计 / 信息 / 目录
│                  InspectorView · InspectorMetadataRows
├── Tabs/          标签栏 + 快捷键
│                  TabStripView · TabCommands
├── Settings/      设置面板
│                  SettingsView · AppSettings
├── CLI/           CLI socket host(消费 MarpleKit/CLI 协议)
│                  CLIServer · CLIHandlers · AppModel+CLI
├── Backup/        备份 UI + 调度
│                  BackupBrowserView · BackupScheduler
├── Shared/        跨视图复用
│                  Tokens(设计 token)· FlowLayout · TypeIcon · DateFormatters
└── Resources/     Assets.xcassets
```

### MarpleiOS/ —— iOS 壳(SwiftUI,只读 reader),消费同一颗核

```
ios/MarpleiOS/
├── MarpleiOSApp.swift   @main
├── App/                 ReaderModel(@Observable 中枢,持 Catalog)· SetupView
├── UI/                  RootView · SidebarScreen · EntryListScreen · DocScreen · MarkdownTextView
└── Vault/               IOSVaultClient(VaultClient 实现,写方法一律抛 read-only)
                         ICloudMaterializer(iCloud 下载;VaultChangeSource 角色)· VaultBookmark
```

## 依赖方向

`Model/` 在最底。`Schema/`·`Vault/`·`Indexer/`·`Catalog/`·`Markdown/`·`Nav/`·`Session/` 只往下依赖 `Model/`,横向之间基本不互引。两层壳 `import MarpleKit`,核绝不反向依赖任何 UI。

**唯一具名横向例外**:`Schema/VaultSchema` 复用 `Indexer/` 的 `YamlFrontmatter` 解析 schema 覆盖文件。

> Swift 机制提醒:同一 target 内文件互相自动可见、无需 import;只有跨 target 才写 `import MarpleKit`。子文件夹纯粹是给人看的组织,SwiftPM 递归编译 `Sources/<target>/` 下所有 `.swift`。所以"层级单向"是君子协定、编译器不强制;真要强制某条边界(违规即编译报错),再把那块拆成独立 target。

## QUA-218 终态关键事实

- **Catalog 是唯一 L2 状态 owner**:`entries` 源快照(QUA-229)+ counts/themeIndex/visibleEntries/relationGraph/searchIndex 派生都算在它身上,壳只读(以 `var entries { catalog.entries }` facade 转发)。`entries` 只能经 `catalog.publish`(陈旧守卫,refresh 路径)/ `catalog.mutateEntries`(乐观编辑)改。
- **统一 generation / 单飞**:`RefreshAuthority`(actor)给每趟 reconcile→reload 发 `pass`,陈旧 pass 发布即丢弃;`derivedGeneration` 是独立轴(乐观单条编辑等 refresh 之外的触发也能让后台派生重算)。
- **NameResolver = 全库唯一两级名字匹配**:wikilink 解析与实体引用共用它(第一级逐字保旧命中,第二级共用 foldedKey 兜底)。
- **规则① 实体引用 / 规则② 容器** 两套引擎 + 具名例外:`RelationsIndex.annotationAnchor`(annotation 章→书 remap)、`SourceResolver` PDF 源的 Jaccard 模糊匹配。
- **VaultChangeSource 契约**:Mac 用 `VaultWatcher`(FSEvents),iOS 用 `ICloudMaterializer`(iCloud 下载);两边都路由到 `catalog.refresh`。
- **写回 primitive(`SessionWriter`/`MetadataWriter`/`FrontmatterPatch`)已沉入 MarpleKit**;iOS 只读是**产品选择**,不是平台限制——`IOSVaultClient` 的写方法存在但一律抛 read-only。

## 下沉边界(平台分叉决定的终态,非过渡欠债)

QUA-229 把最后一块真共享的状态——`entries` 源快照 + 陈旧守卫的发布——沉进了 Catalog
(`catalog.publish(_:pass:)` / `mutateEntries`)。**剩下还在壳侧的,是平台真分叉的部分,
不是欠债**:把它们硬塞进核只会反向优化(把壳的 UI 状态倒灌进 MarpleKit)。逐条说明边界:

- **reconcile 编排**仍由各壳供给(`catalog.refresh(body)` 仍收一个 body 闭包)。因为两端
  的 reconcile 真不一样:macOS 用长期存活的注入式 `cliIndexer`(还被 `CLIServer`/boot 直接
  用);iOS 每次新建 `VaultIndexer`,且 reconcile 前要先 `materializeMarkdown`(iCloud 下载,
  Mac 没有)。统一它要么把 client/indexer 连带 CLIServer/boot 接线搬进核,要么散成几个 hook
  闭包——耦合量不降反升。
- **post-publish 反应**两端共享零行,因为是「两种交互形状各自的反应」,不是同一逻辑写两遍:
  macOS 发布后刷新它的物化列表(`recomputeVisible`,NSCollectionView data source 的硬需求)、
  读 schema/译本、`persist()`、重载开档、刷回收站;iOS 只 `loadSession`(解析 **Mac 的**标签页
  来只读显示)。iOS 结构上不产生这些反应所消费的活输入(无当前 pane / 无自己的 Spaces /
  无回收站),强行让它跑 = 编造无意义输入 + 背死状态。
- **`persist()`** 写 Workspace/Spaces/UserDefaults,纯壳状态,Catalog(MarpleKit)不该认识这些
  类型——留壳是对的。**`FrontmatterPatch` 组合**(哪个字段写哪个 key)是 UI 语义,同理留壳;
  其**乐观更新单条 `Entry`** 的那一步现经 `catalog.mutateEntries` 改(`entries` 已下沉)。

> 历史:PR3a 决策 3 曾把 `entries` 也留在壳里以控 blast radius,并标注「尚未下沉」。QUA-229
> 核实后:`entries` 该沉、也沉了;reconcile/post-publish/persist 留壳是**平台分叉的正确终态**,
> 不是没做完。所谓「catalog.refresh 完全自洽闭包-free」是当初没看清平台分叉的理想化措辞。
