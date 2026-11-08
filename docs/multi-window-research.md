# 多窗口研究：YAB、Ulysses 与 Marple 的状态边界

状态：研究与设计建议，尚未实现。

## 结论

不应为了保留当前单窗口数据结构，规定「一个 Space 同时只允许一个窗口」。更合适的边界是：共享资料与组织结构，每个窗口拥有自己的阅读会话。

当前问题主要位于 Marple 的应用内状态模型和会话持久化，不是 vault 文档格式。暂没有证据要求迁移文库正文或重做底层文件布局。

应区分四种身份：文档、Space 中固定的入口、正在使用的阅读会话、承载会话的窗口。固定入口可以出现在多个窗口；每个窗口由该入口开启的阅读位置和历史可以不同。

## 调查方法与证据范围

- YAB：本机 0.46.31；官方手册；只读检查 Application Support 下会话 JSON 的字段、ID 关系；通过 `yab mcp` 查询原生设置目录与当前设置；应用二进制字符串。
- Ulysses：本机 Setapp 版 42；官方帮助；主程序及 UlyssesCoreMac 的 Objective-C 元数据；主程序 x86_64 slice 中一段窗口创建方法的反汇编。
- 继续通过 Rex 中的同一个 Claude 线程交叉检查了 Ulysses 元数据。
- 没有取得两款应用的完整源码，没有做实时双窗口编辑或导航实验。持久化样本包括已关闭窗口，字段差异不能证明运行时同步语义。
- Ulysses 本机容器读取被系统拒绝；没有绕过权限。其用户会话存档格式尚未核实。
- 没有修改两款应用的用户资料、设置或已有标签。

临时原始证据：

- `/tmp/marple-yab-schema.json`：仅字段类型。
- `/tmp/marple-yab-session-analysis.json`：去除标题与 URL 后的跨文件 ID/字段比较。
- `/tmp/marple-ulysses-objc.txt`、`/tmp/marple-ulysses-core-objc.txt`：`otool -ov` 输出。
- `/tmp/marple-ulysses-window-disassembly.txt`：主程序反汇编。

这些临时文件不应作为项目的运行依赖。

## YAB：Space 与窗口是两条维度

### 已观察到的存储结构

`~/Library/Application Support/Yab/` 中存在：

```text
spaces.json                              空间的 ID、名称、外观、登录隔离等
windows.json                             open / closed 窗口 ID
session-<spaceID>.json                    空间层会话
session-window-<windowID>-<spaceID>.json   窗口 × 空间会话
```

空间层和窗口层会话都有 `tabs`、`active`；部分有 `nothingInFront`。标签记录有 `id`、`home`、`url`、`pin`、`kept`、`folder`、`folderPath` 等，窗口层记录还出现 `shared`。

同一 Space 的多个窗口文件中有大量相同的标签 ID，各自保存自己的 `active`。这支持「共享标签身份、独立窗口会话」这一模型，但不能单凭这些 JSON 判定哪个文件是实时权威、合并规则是什么。

`home` 与 `url` 是不同字段。官方固定标签文档说明：标签记住固定时的地址，浏览到别处后仍可返回原始入口。这明确区分了稳定入口与当前访问位置。

### 已核实的产品设置

原生 action 目录提供：

```text
settings.set.today-every-window
Today's tabs in every window
value: Boolean
```

本机当前值为 `true`。应用内设置文案为：

> Share Today tabs across windows in the same space. Each window keeps its selected tab.

因此，普通标签是否跨窗口共享本身是产品策略，而「当前选中项属于窗口」是另外一回事。不能把某一版手册中的“each window keeps its own tabs”当成 YAB 永远不共享普通标签。

官方 guide 另有 Blank Window：标签归 “This Window”，不进入 Space 侧栏，但使用来源 Space 的登录身份。这进一步说明 Space、窗口、登录上下文和标签集合可以分开。

### 尚未证明

- 同一个共享标签在两窗口同时导航时，URL、前后退历史、滚动位置是否独立。
- 对共享普通标签执行关闭，具体影响哪个范围。
- 渲染实例是复制、迁移还是其他管理方式。
- `shared` 标记的完整语义及跨窗口变更合并算法。

**可借鉴的是状态边界，不是臆测它的全部内部算法。**

资料：

- https://yetanotherbrowser.com/manual/windows
- https://yetanotherbrowser.com/manual/spaces
- https://yetanotherbrowser.com/manual/pinned-and-kept

## Ulysses：文库、窗口、编辑器分层

### 应用与窗口

Objective-C 元数据可见：

```text
ULApplicationState
  storageController
  modelRootNode / modelTreeController
  windowControllers
  addWindowController:
  newWindowUsingBlock:
  restoreWindowWithIdentifier:state:completionHandler:

ULWindowController
  initWithContentMode:storageController:storeInterface:coachingState:
  selectionController
  sheetTableViewController
  sheetSearchQuery
  editorSplitView
  currentInterfaceState / currentWindowContent / persistentSelection
```

应用级存储与窗口级选择、搜索、界面状态明确分离。初始化签名支持向窗口注入存储服务；仅凭属性名不能断言所有控制器实例的共享关系。

### “新标签”确实复用新窗口路径

定位方法：

```text
-[ULWindowController _openNewWindowWithModelNodes:layout:tabbed:]
x86_64 地址：0x100325dbb
```

可见调用顺序：

1. 取得 `applicationState`。
2. 调用 `newWindowUsingBlock:`。
3. 对新控制器调用 `selectModelNodes:withOptions:` 与 `setLayout:`。
4. 若 `tabbed` 为真，取得两个控制器的 `window`，调用 `addTabbedWindow:ordered:`。

这是反汇编中的实际调用证据，不只是出现了一个 API 名字。Ulysses 这里的标签使用 AppKit 原生窗口标签机制：先有独立窗口内容，再组合成标签。

它不是 Marple 当前 `NavTab` 文档历史结构的同义物。无需给 Marple 再加一层顶部原生标签，但可以借鉴「窗口只是容器，内容会话能独立存在」的边界。

### 编辑器会话

元数据可见：

```text
ULEditorSplitView
  primaryEditorContainer / secondaryEditorContainer
  activeEditorIndex / splitMode
  persistentEditorState

ULEditorController
  editorHistory
  mainEditorSelection
  previousEditorSelections: NSMapTable
  previousScrollPositions: NSMapTable
  shownSheetHandleNodes / loadedSheetHandleNodes

ULEditorHistory（UlyssesCoreMac）
  backwardItems / forwardItems
  pendingItem
```

历史、选择、滚动位置属于编辑器层。一个窗口可以容纳两个编辑器，而不要求复制文库。

### 文档与保存

框架中另有 `ULSheetHandle`、`ULSheet`、`ULAtomicString`、`ULTextStorage`：

- `ULSheetHandle` 有加载、文档观察、`currentVersion`、`conflictVersions` 和 `changeToken`。
- `ULSheet` 持有 `_text: ULAtomicString`，并有内容变化观察。
- `ULTextStorage` 有针对文本范围变化的观察通知。

这些是文档模型与展示/编辑状态分离的证据，但不足以证明两个编辑器一定共享同一个文本对象，也不足以还原并发编辑、外部修改、撤销的精确规则。不能将“单笔记编辑锁”说成 Ulysses 的做法。

资料：

- https://help.ulysses.app/en_US/dive-into-editing/split-view
- https://help.ulysses.app/en_US/the-library/projects
- https://help.ulysses.app/en_US/the-library/ulysses-library

## Marple 的问题具体在哪里

1. `Navigation.swift` 的 `NavTab` 同时承担固定入口属性（`pinnedLocation`、别名）和阅读会话（`history`）。`pinnedLocation` / `identityLocation` 已经是分层的起点，可保留。
2. `WorkspaceSpace` 持有 `workspace` 与 `isBrowsing`；`Workspace` 又同时持有树、标签值、`activeID`。将它共享后，组织结构和当前阅读状态会一起共享。
3. `TabGroup.isCollapsed` 把显示状态放进组织树。多窗口时应考虑移到窗口的展开状态集合，避免一个窗口折叠导致另一个也折叠。
4. `Catalog` 同时管理全库 entries/索引/刷新权威和 `visibleEntries`、`searchMatches`、`openEntry` 等视口派生数据。共享整个 Catalog 会串窗口，复制整个 Catalog 则会复制重计算与刷新调度。
5. `AppModel` 兼任库服务、导航、笔记草稿和保存入口；`MarpleWindowController` 又直接拥有 `AppState`，服务生命周期跟着窗口走。
6. `PersistedWorkspaceSpace` 将共享组织结构与 `activeIndex`、`isBrowsing` 混存。`PersistedTab` 没有保存稳定标签 ID，树叶使用数组索引，不能直接用于跨窗口引用。

需要纠正此前讨论中的表述：**Marple 并没有将完整前后退历史写入存档。** `PersistedTab` 明确不保存历史；`persist()` 保存的是 `identityLocation`。问题是运行时所有权混合，以及持久化同时保存组织结构和窗口选择，不是“历史已经被错误同步到手机”。

## 推荐的目标模型（Marple 设计，不声称是对方源码）

```text
LibraryStore（应用级）
  文档、元数据、共享索引与唯一刷新调度
  SpaceStore
    Space ID / 名称 / 图标 / 归档标记
    固定入口与分组树：稳定 ItemID、homeLocation、别名
  DocumentStore
    按文档键共享内容、草稿、版本与保存状态

WindowSession（每窗口）
  windowID / activeSpaceID / 布局
  SpaceSession[spaceID]
    activeItemID / 浏览或阅读状态
    搜索、筛选、排序、展开状态
    临时页面
    ReaderSession[itemID]
      当前位置 / NavHistory / 滚动与选择 / 阅读派生状态
```

这是责任分界，不要求每个框都立刻新建一个类。先保留 `AppModel` 作为视图 facade，逐步更换状态来源。

### 建议第一版语义

- 同一 Space 可以在多个窗口打开。
- 固定入口、别名和分组结构共享；展开状态、当前页和导航独立。
- 临时页面先按窗口独立。不要照搬 YAB 的所有共享设置；若以后确有需求，再加共享临时页策略。
- 从固定文档 A 跟链接读到 B，只改变本窗口 ReaderSession，不改变其他窗口，也不改变固定入口的 homeLocation。
- 关闭阅读会话与移除固定入口是两种操作；删除固定入口时，其他窗口正在读的内容可转成临时会话，保留历史。
- 关闭窗口不删除 Space 或文档。
- 两窗口打开同一可编辑笔记，应优先共用按文档键管理的草稿和保存状态。不要各自缓存一份正文再各自整体覆盖文件。外部修改另需版本校验和冲突处理。
- 文档编辑撤销跟文档；组织结构操作撤销跟共享组织模型；窗口导航不进入这些撤销栈。具体 UI 焦点路由需要验证。

### 持久化与手机同步

- 共享 Space 定义和窗口会话分开编码；物理上可先共用一个版本化存档，保持应用层单写者，不必机械照抄 YAB 的文件数量。
- 给固定入口保存稳定 ItemID；窗口的激活项和 ReaderSession 用 ID 引用。
- 迁移旧存档时，一次性分配 ID 并提交；旧固定页成为共享定义，旧临时页和当前位置成为第一个窗口的会话。旧历史本来就没落盘，不需要迁移不存在的历史。
- 手机端可以继续以 Space 展示共享入口；如果要保留“Mac 上打开的”中临时页的含义，由应用级 SessionWriter 汇总所有窗口。必须明确重复条目的去重以及单一 activePath 的选择规则，不能让多个窗口轮流覆盖同一文件。

## 实施前的验证边界

先在单窗口下完成数据归属拆分，再增加第二个窗口。用以下行为验收，而不是只验证能创建 NSWindow：

- 两窗口同 Space：选页、搜索、后退互不影响。
- 改固定入口名称/分组，两边同步，折叠状态互不影响。
- 两窗口由同一个固定入口导航到不同文档，入口身份不变。
- 移除固定入口不导致另一窗口正在读的页面丢失。
- 同文档编辑看到同一份草稿；外部修改不被静默覆盖。
- 文档移动/删除通知到所有相关会话；关闭一个窗口不停止共享服务。
- 重启恢复所有窗口引用；索引、监听、CLI 与手机快照发布仍只有一个权威入口。

这比规定 Space 独占窗口需要更多基础工作，但它解决的是现有模型的扩展边界，并可复用于分屏、辅助阅读与多窗口。
