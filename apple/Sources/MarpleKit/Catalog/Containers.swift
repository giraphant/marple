import Foundation

// MARK: - 规则②：容器（同 <slug>/ 文件夹 = 同对象的目录式处理）
//
// 机制是通用的：slug 提取 → 同 slug 成员收集 → overview 判别 → 子页按路径排序。
// 语义差异保持有名字（QUA-218 公理 6）：
//   book  — overview 按类型判别（type=book），无章节也展示（空书可见）；
//   topic — overview 按 kind=overview 判别（路径首页兜底），单页不展示（噪音）；
//   talk  — 不走 slug 容器：talk.md↔transcript.md 是固定文件名配对，见 siblingEntry。
// BookContext / TopicContext 保持公开形状（视图零改动），本文件是规则②的
// 统一入口与唯一叙述处；PR3/PR4 的新消费者用 ContainerContext。

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
