# QUA-218 设计：单核心 + Catalog 架构重建

- 日期：2026-06-11
- Issue：QUA-218（代码综合优化）
- 状态：设计已与用户对齐，待 spec 评审

## 1. 背景与动机

App 功能已成熟，但维护时"加新东西"成本偏高。审计结论：代码健康度整体良好
（无 TODO 残留、无死代码、仅 3 处编译警告），真正的结构性问题有两个根因：

1. **派生状态没有 owner**。AppModel（1919 行）把派生状态、会话状态、瞬时 UI
   状态搅在一个 `@Observable` 里，"何时重算"靠每个 mutation 点手工记得调
   `rebuildIndexDerived + recomputeVisible + recomputeOpenDerived`。历史上
   QUA-198（OOM）、QUA-212（重复 reconcile）都是这个根因的症状。
2. **关联派生是同一模式的 N 份手写**。author→作品、paper→journal、book→章节、
   topic→成员、talk↔transcript、annotates、wikilink——95% 在机械上同构
   （提取 → key→[values] 索引 → 正反查 → 排序），却分散为七处胶水，且四套
   名字匹配器规则互不一致（wikilink / journalEntry / authorProfile /
   speaker 列复用 hack）。每加一个引用字段就要再手写一遍。

另一个独立动机：**iOS 与 macOS 需要共享地基**。iOS 的 `ReaderModel`（293 行）
是 AppModel 的手写迷你复制品；今后 iOS 扩功能不应再复制。

## 2. 设计公理（与用户对齐的认知）

1. Marple 是投影机：**外部真相(vault) → 派生理解 → 会话导航 → UI**。
2. 派生状态全部是 `f(vault, schema)`，永远可以丢弃重算；会话状态属于用户，
   持久化在 `.marple/`；瞬时 UI 状态既不派生也不持久。
   判定规则：**选择/意图归 Session；凡 f(vault, 选择) 可算出的归 Catalog。**
3. 关联的本质是少数通用规则 + 一张声明表。"字段名 = 实体类型名"
   （author/journal/topic）是 vault schema 的有意设计；"同文件夹 = 目录式处理"
   （books/topics/talks 的 `<slug>/` 结构）同样是有意设计。
4. 声明表是**数据**不是代码。它是 quasi schema 知识在 Marple 里的唯一落点，
   将来 quasi subtree 合并时可直接共享；远期可开放 UI 编辑（本期不做编辑器）。
5. 平台差异只存在于 UI 壳和 OS 驱动。核心带着"iOS 用不到的能力"零成本——
   不给前端就调度不了。
6. 这不是"通用引擎/平台化"：声明表是几行数据，规则引擎只有两条，语义性的
   例外保持为有名字的 Swift 代码。与早先"不造通用引擎"的决定不冲突——
   当时反对的是为解耦 schema 而造引擎；现在是机制本来就通用，声明表自然是数据。

## 3. 目标结构

### 3.1 静态结构：一个核心，两个薄壳

```
┌─ 壳A: Marple (macOS) ─────────────────┐   ┌─ 壳B: MarpleiOS ──────────────┐
│  视图  Sidebar / Browse / Reading      │   │  视图  书库列表 / DocScreen     │
│        Inspector / Tabs / Settings     │   │        talk播放 / Mac打开的     │
│  窗壳  NSSplitViewController + 拖拽    │   │                                │
│  OS驱动                                │   │  OS驱动                        │
│   FSEvents ──→ VaultChangeSource       │   │   iCloud感知/前台 ──→ 同一契约  │
│   Process  ──→ Superset 启动           │   │                                │
│   socket   ──→ CLI server 宿主         │   │                                │
│  AppModel = 组合根 + 瞬时UI态           │   │  ReaderModel = 组合根          │
└──────────────────┬─────────────────────┘   └──────────────┬─────────────────┘
                   │            只通过 MarpleKit 公开 API      │
┌──────────────────┴─────────────────────────────────────────┴─────────────────┐
│                        MarpleKit ＝ 程序本体                                   │
│  L4 Session    Nav(spaces/tabs/history/savedViews) · SessionStore(持久化)     │
│   书桌与写入    MetadataWriter(写回+写穿) · SessionWriter(open-tabs.json)      │
│  L3 Document   渲染模型 · 大纲 · talk时间轴 · wikilink ＝ f(vault, path)       │
│   阅读                                                                        │
│  L2 Catalog ⭐ Catalog — 唯一重算入口 · generation/单飞 收拢于此               │
│   编目         RelationGraph(正反边) ← 规则①实体引用 + 规则②容器               │
│                NameResolver(全库唯一) · 搜索索引 · counts · 向量               │
│  L1 Vault      VaultClient(读/写/trash) · frontmatter→Entry · SQLite缓存      │
│   馆藏登记                                                                    │
│  L0 Schema  ⭐ 声明表(数据): 实体别名 · 容器约定 · 类型→图标/色 · 校验          │
│   词汇表       内置默认 + vault 配置文件覆盖                                   │
└───────────────────────────────────┬───────────────────────────────────────────┘
                                    │
                      vault/ —— 磁盘上的外部真相 (iCloud 同步)
                      quasi pipeline、agents、用户 都在写它
```

依赖规则：**层内只许向下 import；壳与 OS 的接触点收敛为三个小契约**
（VaultChangeSource、Superset 启动、CLI 宿主）。平台 UI 框架 import 只许出现
在壳里（既有例外：`Markdown/Platform.swift` 的 typealias，按现状保留并注明）。

### 3.2 动态数据流：两个环

```
读环 (真相 → 屏幕)
  vault变更 ─→ VaultChangeSource(壳喊一声) ─→ Catalog.refresh()
            └ 单飞门 + generation 防竞态      │
                                             ├→ L1 重读受影响 Entry
                                             ├→ L2 重编目录: 图/搜索/counts
                                             └→ @Observable 失效 → 视图自动更新

写环 (编辑 → 真相)
  UI编辑字段 ─→ MetadataWriter ─① 写 vault 文件 (真相先行)
                              └② 乐观 patch Catalog (单 entry, UI 立即反馈)
  …0.4s 后 FSEvents 触发读环，以 vault 全量为准兜底校正
```

**写穿纪律（硬规则）**：乐观 patch 只许修改单个 entry 的派生投影，
永远不许替代全量重算；全量重算永远以 vault 为准。

### 3.3 L0 Schema：声明表

现状中"vault 里的东西是什么意思"散在四处，实为同一张表的碎片：
`MarpleKit/Conformance/`（校验）、`Marple/Shared/TypeIcon.swift`（显示）、
`IndexFields` 的列映射、indexer 里 speaker→author 的硬编码列复用。

收拢为 `MarpleKit/Schema/` 的一张声明表：Swift 结构化数据作内置默认值，
`<vaultRoot>/schema.yaml` 存在时逐项覆盖（YAML，与 vault frontmatter 同生态，
quasi 可共读；**不放 `.marple/`**——那是可 `rm -rf` 重建的缓存区）。
本期只实现"读取覆盖"，不做编辑器：

```
实体引用:  author  ⊇ 字段 [author, speaker, creator]
          journal ⊇ 字段 [journal]
          topic   ⊇ 字段 [topics]
容器:      books/<slug>/、topics/<slug>/、talks/<slug>/ → 目录式
          (overview 判别: kind/type；子页排序: 路径)
显示:      EntryType → SF Symbol 名 / tint 名 (平台无关字符串)
校验:      现 Conformance 规则改为从表读取
```

声明表喂养关系：L1 解析时的字段别名归一、L2 两条规则、壳的图标/颜色、校验。

### 3.4 L2 Catalog：编目层

**Catalog**（取图书馆目录隐喻：从馆藏派生、可随时重编、多路检索、带交叉引用）
是全部派生状态的唯一 owner：

- 唯一入口 `catalog.refresh()`（接 VaultChangeSource）+ 单 entry 乐观 patch 接口。
  现存四套各自为政的防竞态机制（loadIndexGeneration、searchMatchQuery 版本号、
  deferredDerivedTask、RefreshGate）收拢为一套 generation/单飞。
- **RelationGraph**：`(from, type, to, position?)` 正反双向索引。
- **两条规则引擎**：
  - 规则①实体引用：任何 entry 的别名字段值，经 NameResolver 解析为同名实体
    类型的页面，自动产生双向边（正向 paper→author 页；反向 author 页←全部作品，
    按来源类型分组）。
  - 规则②容器：同 `<slug>/` 文件夹 = 同对象的目录式处理（overview + 有序子页）。
    统一替代 BookContext / TopicContext / siblingEntry 三份手写。
- **NameResolver**：全库唯一的名字归一/匹配器（大小写、变音符、标题/文件名
  词干回退）。wikilink 正文解析与实体引用共用。
- 搜索索引（SearchRanker）、theme counts、向量库照旧挂在此层。
- **点名的例外**（有名字的 Swift，不塞进规则）：annotates 的"章节→书 overview"
  锚点重映射；PDF 源的 Jaccard+年份模糊匹配。

被替代删除的胶水（七处合一）：`RelationsIndex` 的 authorIndex/annotationIndex/
authorProfile、`BookContext`、`TopicContext`、`ThemeIndex` 的关联部分、
Inspector 里的 `journalEntry()`/`siblingEntry()`、indexer 的 speaker 列复用。

### 3.5 L4 Session 与写回（下沉 MarpleKit）

- Nav 模型已平台无关，原地。SessionStore（spaces/tabs/savedViews 持久化）、
  MetadataWriter（字段写回+写穿）、SessionWriter（open-tabs.json）全部下沉
  MarpleKit——写回是文件 IO，iOS"只读"是产品选择而非平台限制，能力闲置零成本。
- CLI handler 逻辑本就在 MarpleKit；macOS 壳只保留 socket 宿主。

### 3.6 壳里只剩什么

| 留在壳里 | 原因 |
|---|---|
| 视图 / 窗壳 / 拖拽 | 平台 UI |
| FSEvents watcher (Mac) / iCloud 感知 (iOS) | OS 专属 API，共同实现 VaultChangeSource 契约 |
| Superset 启动 | `Process` 在 iOS 不存在，硬边界 |
| CLI socket 监听 | 产品上仅 Mac 有意义 |
| security-scoped bookmark 差异 | iOS 无 `.withSecurityScope`，各壳各处理 |
| AppModel / ReaderModel | 组合根 + 瞬时 UI 状态（搜索框文字、flash、重命名中） |

## 4. 现有代码 → 目标位置（最小移动原则）

| 现在 | 去向 | 动作 |
|---|---|---|
| `MarpleKit/Conformance/`、`Marple/Shared/TypeIcon.swift`、speaker 列复用 | `MarpleKit/Schema/`（新） | 收拢为声明表 |
| `MarpleKit/Vault/`、`MarpleKit/Indexer/` | 原地（L1） | 不动，仅理清写回原语接口 |
| `RelationsIndex`/`BookContext`/`TopicContext`/`ThemeIndex` 关联部分、`journalEntry()`/`siblingEntry()` | `MarpleKit/Catalog/` RelationGraph + 规则引擎 | 七处胶水删除合一 |
| `MarpleKit/Derivation/`（SearchRanker、向量等） | 改名 `MarpleKit/Catalog/` | 目录改名 + 新增 Catalog 类型 |
| AppModel 内派生状态与重算（约 L497-614 等） | `Catalog` | 搬入；AppModel 留门面转发（过渡期） |
| AppModel 内字段写回（applyPatch + set*） | `MarpleKit/Session/MetadataWriter` | 下沉 |
| `Marple/App/SessionWriter.swift` | `MarpleKit/Session/` | 下沉（注意 CLAUDE.md 的 tab-sync 重装提醒） |
| `MarpleKit/Nav/` | 原地（L4） | 不动 |
| `MarpleKit/Markdown/` | 原地（L3，概念归"Document"） | 不物理移动，避免无谓 churn |
| `Marple/CLI/`、Superset 胶水、`BackupScheduler` | `Marple/Integrations/` | 归拢为"边界"目录 |
| iOS `ReaderModel`（293 行复制品） | 瘦身接 Catalog | 删重复逻辑 |

**明确不碰的雷区**：AttributedStringRenderer/TableAttachment 内部、sidebar
拖拽 sticky-snap 状态机与 validate/accept 调度、NSOutlineView 展开行为、
AppKit 窗壳、IndexDatabase 的 SQLite 结构、FSEvents 0.4s 防抖时序。

## 5. "加新东西"的目标成本

| 场景 | 现在 | 之后 |
|---|---|---|
| 新引用字段（如 translator） | 手写匹配器+索引+UI 胶水 | 声明表一行 |
| 新容器类型 | 复制 BookContext 模式 | 声明表一行 |
| 新 EntryType | QUA-183 长清单 | 声明表行（显示+关联+校验）+ Entry typed 字段仍需少量代码 |
| 新派生（语义搜索等） | 塞 AppModel | Catalog 一个插槽 |
| iOS 加关联面板 | 再手写一遍 | 免费（查 RelationGraph） |

诚实边界：`Entry` 结构体保持强类型，不做全动态记录；EntryType 清单中
解码/列映射的代码部分仍存在，只是缩短。

## 6. 迁移分期（绞杀式，每期独立 PR、可停）

1. **PR1 — L0 Schema**：声明表成形，收拢 Conformance/TypeIcon/别名。行为零变化。
2. **PR2 — L2 关联**：NameResolver + RelationGraph + 两条规则引擎，替换七处胶水。
   四套匹配器归一可能产生边界 case 行为差异——**归一规则差异需逐条列出给用户
   过目，不许悄悄统一**。
3. **PR3 — L2 收口 + L4 下沉**：Catalog 立起，AppModel 派生逻辑搬入、门面转发，
   视图零改动；SessionStore/MetadataWriter/SessionWriter 下沉 MarpleKit。
4. **PR4 — iOS**：ReaderModel 接 Catalog，删手写复制品。此步是"真平台无关"的验收。
5. **PR5 — 收尾**：Mac 视图逐步改绑直读 Catalog/SessionStore，AppModel 瘦身至
   组合根；`Marple/Integrations/` 归位；顺手项（CollectionGridVariant 两处
   MainActor 警告、VectorStore CBLAS 弃用旗标、DateFormatter 收拢）。
6. **延后（各建 Linear issue，PR 引用）**：规则③路径引用（annotates 字段声明化，
   现状能跑，代码标记）、声明表 UI 编辑器、Sidebar 大文件拆分。

## 7. 验证

每期硬性门槛：

- `cd apple && swift test` 全绿（现有 NavigationTests/IndexedEntryTests 等兜底；
  PR2 为 RelationGraph/NameResolver/规则引擎新增单测，覆盖每种现存关联的等价行为）
- iOS：`xcodegen generate` + `xcodebuild test`（CLAUDE.md 流程）
- 用户 GUI 验收清单（每 PR 附）：关联面板（本书/本专题/作者作品/journal/
  talk↔transcript/批注）、搜索与高亮、拖拽手感、tab 同步（PR3 涉及 SessionWriter
  时按 CLAUDE.md 重装 Mac app）
- 完整链路集成测试（PR3 起新增）：临时 vault → 编目 → 查关联 → 开 tab →
  改元数据 → 写穿 → 重编校正，纯 swift test 跑通，不起 app

## 8. 风险

- **匹配器归一的行为漂移**：四套模糊匹配合一套，边界 case 结果可能变。
  缓解：PR2 列差异清单 + 等价行为单测。
- **@Observable 拆分/门面转发的 SwiftUI 细节**：Binding setter 回声、
  @Bindable cell 重渲染等 QUA-95 已知坑。缓解：门面期保持属性签名不变，
  改绑期逐视图小步走。
- **混血期**：PR3–PR5 间架构半新半旧。缓解：每 PR 自洽可发布，可随时停。
- **写穿与 CLI 的竞态**：CLI reconcile 与读环共用 Catalog 的单飞门
  （延续 QUA-212 修复模式），不另起机制。

## 9. 非目标

- 不做声明表 UI 编辑器（本期）
- 不做规则③路径引用的声明化（标记后延）
- 不做 Entry 动态记录化 / 运行时类型系统 / 可编辑 profile 引擎
- 不做 big-bang 切换
- 不改任何用户可见行为（除 PR2 列明并经确认的匹配边界 case）
