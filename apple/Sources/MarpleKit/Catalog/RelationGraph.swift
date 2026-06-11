import Foundation

/// 关联边的种类。本期只有规则①产出的两类：topic 成员走 TopicMembership
/// （slug 键），journal 链接保持按需查询（NameResolver.journalEntry）——
/// 为守住"立即可见"时序，PR3 Catalog 接管惰性调度后再入图。
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
    private let byFrom: [String: [Edge]]
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

    /// 规则①实体引用 + annotates 例外，线性扫描建图。守卫逐字对齐旧
    /// buildAuthorIndex（仅 paper/book、e.author 直读、key 不 trim）与
    /// buildAnnotationIndex（仅 note、悬空目标保留原始路径、overview
    /// slug 表只建一次）。
    public static func build(_ entries: [Entry]) -> RelationGraph {
        var edges: [Edge] = []
        var works: [String: [Entry]] = [:]
        var byPath: [String: Entry] = [:]
        for e in entries where byPath[e.path] == nil { byPath[e.path] = e }
        let overviewBySlug = bookOverviewBySlug(entries)

        for e in entries {
            if e.type == .paper || e.type == .book {
                for name in e.author {
                    works[name.lowercased(), default: []].append(e)
                }
                for (i, name) in e.author.enumerated() {
                    for page in NameResolver.authorPages(named: name, in: entries) {
                        edges.append(Edge(from: e.path, kind: .authoredBy, to: page.path, position: i))
                    }
                }
            }
            if e.type == .note, let target = e.annotates, !target.isEmpty {
                let anchor = byPath[target].map { annotationAnchor(for: $0, overviewBySlug: overviewBySlug).path } ?? target
                edges.append(Edge(from: e.path, kind: .annotates, to: anchor))
            }
        }
        return RelationGraph(edges: edges, worksByAuthorKey: works, entriesByPath: byPath)
    }
}
