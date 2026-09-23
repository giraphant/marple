# Archive 目录合集

合集以文件夹管理成员，只作用于 Archive：

```text
vault/archives/
├── a/archive.md
└── 维修资料/
    ├── collection.md
    └── b/
        ├── archive.md
        ├── manifest.yaml
        └── originals/
```

`collection.md` 可以为空；首个 H1 是标题，否则用目录名，正文可写笔记。
不需要合集 manifest、members 列表或每件 Archive 的 collection_id。只支持一层合集，
Archive slug 在所有合集和根目录中须唯一。Archive 的 manifest/0.2 和 originals 内容保持原样。
同一目录不能同时有 archive.md 与 collection.md，也不跟随符号链接。

## GUI

合集与单件档案在同一个浏览列表里平行排列、共同排序；根目录不再有单独的合集区域或新建按钮。
网格使用叠放封面，列表使用文件夹条目，表格使用合集行（名称、数量与首件档案标题/作者等内容）。
单击可选中，双击或 Return 进入合集；进入后顶部仅显示返回与当前位置。

- 空白处右键「新建空合集」：创建只有 collection.md 的空文件夹，始终显示在列表中。
- 多选档案右键「组成新合集」：创建「新合集」（重名自动加序号）并移动所选目录。
- 拖一件或多件档案到另一件上：双方一起形成新合集；对自身选择拖放不执行。
- 拖到已有合集行或其成员上：移入该合集；不产生嵌套合集。
- 右键「移入合集」选择现有合集；成员右键「移出合集」移回根目录。
- 合集右键可打开、重命名、编辑 collection.md；不会把它当普通档案批注或删除标记文件。

创建并分组是同一个预检、锁和恢复记录覆盖的操作。搜索根目录时，成员命中的合集保持
合并显示；合集内搜索限于成员。这里的合集与右侧栏用于固定页面的文件夹独立。

参考了 Tropy 的 `src/components/item/cover-image.js`（叠层封面）与
`src/components/item/iterable.js`（条目拖放合并）；数据依然使用 Marple 的独立 Archive 目录。

## Agent / CLI

需要运行连接到目标工作区的 Marple。命令返回 JSON；路径可使用工作区相对路径或绝对路径。

```sh
marple-cli collections list
marple-cli collections create '维修资料'
marple-cli collections move vault/archives/a/archive.md --to 'vault/archives/维修资料' --dry-run
marple-cli collections move vault/archives/a/archive.md --to 'vault/archives/维修资料' --request-id 40CC70F8-C501-410E-AF5C-15ADB7C08966
marple-cli collections rename 'vault/archives/维修资料' '手机维修'
marple-cli collections move 'vault/archives/手机维修/a' --to vault/archives
marple-cli collections status 40CC70F8-C501-410E-AF5C-15ADB7C08966
```

`create NAME --items PATH...` 可在同一次操作中新建并加入选中的档案；省略 `--items` 就创建空合集。
`move` 可给多个 Archive 路径。整批预检，重名不覆盖；`--dry-run` 不写磁盘，返回计划的 moves
和 updatedReferences，inventory 是操作前的状态。真实写入返回操作后的 inventory。
请求 UUID 可由客户端生成，也可显式指定。响应丢失后查 status；相同 UUID、相同参数只返回
原回执（replayed=true），不会重复执行；相同 UUID 配不同参数拒绝。未写入日志的请求返回
request_unknown，此时先核对当前 list 和目录状态，不盲重放未知结果。

## 引用、并发与恢复

Marple 受控移动会更新支持的路径型 wiki 链接、普通 Markdown 相对链接/引用定义，以及
frontmatter 的 archives、annotates、path 字段；移动页面的相对链接会重新计算。
代码示例与普通散文保持不变，原件目录内文件不改写。只含 slug/标题的 wiki 链接不需要移动。
已打开标签、固定目标及前后导航历史同步到新路径。任意自定义文本格式不属于自动改写合同。
Finder 的移动能被重新发现，但不会执行上述引用修复。

`.marple/archive-collections.lock` 用 flock 协调本机 Marple 整理与 Quasi 采集：整理排他，
采集共享。锁忙立即拒绝。编辑器、audit agent 和其他设备不受此锁约束，整理时请停止这些写入。
多目录移动和引用编辑不是文件系统事务，也不保证云盘的跨设备原子同步。

操作记录位于 `.marple/collection-operations/<UUID>.json`，包含移动映射与原始引用字节。
正常失败会回滚本次写入；如果检测到外部编辑、回滚失败或进程中断，则保留未完成记录并拒绝
后续写入。此时先备份、检查记录中的旧/新路径和 edits，人工决定完成还是回退，并核对原件与
引用。不要直接删日志再重试。完成的记录是回执，不参与合集成员关系。

## Quasi 适配

Quasi 的 status、resolve、URL owner 扫描和 collect 同时支持根目录与标记的一级合集。
现存对象使用观察得到的 exact path；新建仍在根目录。目录路径参与 revision，移动后必须
重新 status。Topic archives 字段允许合集这一层。manifest/0.2 不变。
对应合同见 Quasi 仓库 `docs/ARCHIVE_STORAGE.md`，发布交接见
`docs/ARCHIVE_COLLECTIONS_RELEASE.md`。本次不代发 Quasi 版本。
