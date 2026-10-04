# Archive 字段合集

每份 `archive.md` 可以有一个可选的 `collection` 文本字段。它表示当前整理归属；
`topics`、`themes` 等列表字段仍然可以有多个值。

```yaml
---
type: archive
title: Apple iPhone 15 官方维修手册
collection: 苹果维修手册
topics:
  - repair-morphology-interface-control
---
```

合集由字段值汇总，不保存独立合集文件、目录映射或成员清单。没有成员的合集自然消失。
设置、替换、清空和重命名只改 `archive.md` 的 `collection` 字段；文档正文、相对链接、
manifest、originals、打开的页面和文件路径保持不变。重命名为已有名字会合并归属。

## GUI

Archive 列表和网格的「分组依据」菜单提供「不分组」、collection 和库中实际存在的
顶层简单字段。文本、数字、布尔值按值分组；topics/tags/themes 等列表逐项分组，
同一份材料可以在多个组中出现。空值进入「未填写」。嵌套 YAML 对象不作为分组字段。
分组作用于当前搜索、筛选后的结果；组内沿用当前排序，组头支持数量排序。

- 「不分组」只平铺显示，不清空字段；这个视图选择会保留到下次启动。
- 单击组头展开或收起；菜单也提供展开/收起全部分组。
- 多选档案右键「组成新合集」输入名字，或者「移入合集」选择已有值。
- 「移出合集」清空所选档案的 collection，保留档案与原件。
- 详情栏「合集」提供单选以及新名字入口。
- 合集组头右键可以重命名或对当前组内材料批量设置归属、打开页面。
- 按 collection 分组时，拖到组头或其成员上更换归属；拖到未归组材料上会提示输入新合集名。
  拖到「未填写」组头清空归属。按其他字段分组时不通过拖拽修改字段。

## CLI

```sh
marple-cli collections list
marple-cli collections assign vault/archives/a/archive.md --to '维修资料' --dry-run
marple-cli collections assign vault/archives/a/archive.md --to '维修资料' --request-id 40CC70F8-C501-410E-AF5C-15ADB7C08966
marple-cli collections rename '维修资料' '手机维修'
marple-cli collections remove vault/archives/a/archive.md
marple-cli collections status 40CC70F8-C501-410E-AF5C-15ADB7C08966
```

路径可为工作区相对路径或绝对路径，可传目录或 archive.md。`create NAME --items ...`
保留为 assign 的快捷方式，必须提供成员。旧版 `move --to DIRECTORY` 已停用，避免旧客户端
把目录路径误写为合集名字。JSON inventory 中 `collections[].path` 保留为兼容的标识字段，
现在取值为合集名字；新操作的 `moves` 始终为空，`updatedReferences` 列出写入的 archive.md。

批量写入先验证全部成员，再修改文件。共享的 `.marple/archive-collections.lock` 继续与
Quasi 采集协调；带 requestID 的日志继续支持重放/状态查询和中断恢复。旧操作回执仍可查询，
未完成的旧日志仍会阻止新写入。

## Quasi 兼容

配套 Quasi schema 增加可选的单值 `collection`，并在补采/专题成员更新时保留它。
使用本版本写入新字段前，应同时更新 Quasi；旧版严格 schema 会将此字段视为未知字段。

## 旧库

读取兼容旧的嵌套 archive 目录，但不再根据父目录或 collection.md 推断归属。
尚未写入 collection 的材料显示在「未填写」，也可以选择「不分组」查看全部材料。
此程序改动不会自动搬动旧材料，也不会删除旧 collection.md 中的说明。
旧目录归属转成字段、目录展平和引用修复属于单独的数据迁移步骤。

实现参考 FSNotes `FSNotes/Helpers/Sidebar.swift` 的虚拟标签节点：视图中的分组不要求
对应一个实际文件夹。仍使用 Marple 现有的 AppKit 列表、表格和网格交互。
