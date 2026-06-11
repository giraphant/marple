import Foundation

// MARK: - 规则②：容器（同 <slug>/ 文件夹 = 同对象的目录式处理）
//
// 机制是通用的：slug 提取 → 同 slug 成员收集 → overview 判别 → 子页按路径排序。
// 语义差异保持有名字（QUA-218 公理 6）：
//   book  — overview 按类型判别（type=book），无章节也展示（空书可见）；
//   topic — overview 按 kind=overview 判别（路径首页兜底），单页不展示（噪音）；
//   talk  — overview 按类型判别（type=talk），transcript 为成员（同 book，常见
//           1:1，同 talks/<slug>/ 文件夹）。替代旧 siblingEntry 固定文件名配对。
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
    case .talk, .transcript:
        return talkContext(for: entry, in: entries)
    default:
        return nil
    }
}

/// 规则②的 talk 容器：`talks/<slug>/` 下 talk.md(overview) + transcript.md(成员)。
/// 与 book 同构（overview 按 type 判别），只是成员类型为 transcript、常见 1:1。
/// 替代旧 siblingEntry 固定文件名配对（QUA-218 规则②统一三/四份手写）。
public func talkContext(for entry: Entry, in entries: [Entry]) -> ContainerContext? {
    guard entry.type == .talk || entry.type == .transcript,
          let slug = talkSlug(entry.path) else { return nil }
    let members = entries.filter { talkSlug($0.path) == slug }
    let overview = members.first { $0.type == .talk }
    let children = members.filter { $0.type == .transcript }.sorted { $0.path < $1.path }
    guard overview != nil || !children.isEmpty else { return nil }
    return ContainerContext(slug: slug, overview: overview, children: children)
}

/// `vault/talks/` 后第一段路径分量，或 nil。镜像 bookSlug / topicSlug。
private func talkSlug(_ rel: String) -> String? {
    guard rel.hasPrefix("vault/talks/") else { return nil }
    let rest = rel.dropFirst("vault/talks/".count)
    guard let first = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first,
          !first.isEmpty else { return nil }
    return String(first)
}
