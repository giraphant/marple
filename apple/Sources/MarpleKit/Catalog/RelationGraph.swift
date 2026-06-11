import Foundation

/// 关联边的种类。规则①实体引用（author/journal/topic 同构：文档某字段引用某
/// 实体类型的页，正向解析器在 chips/链接处，反向边在此入图供实体页列出引用它的
/// 文档）产出三类；规则③路径引用产出 annotates。
public enum RelationKind: String, Sendable, Hashable {
    case authoredBy   // 文档 → 作者页（反向：作者页 ← 作品/讲座/图像）；position = author 下标
    case inJournal    // 论文 → 期刊页（反向：期刊页 ← 本刊论文）
    case inTopic      // 成员 → 专题页（反向：专题页 ← 成员；正向 chips 用 topicEntryBySlug）
    case annotates    // 笔记 → 被标注文档（边忠实 frontmatter 目标；章→书
                      // overview 上卷由 relations() 容器附属聚合在查询期完成）
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

    /// 规则①实体引用 + 规则③路径引用（声明表驱动），线性扫描建图。
    /// authoredBy：任何带 author 的 entry → 同名作者页（声明表的 author 别名
    /// speaker@talk / creator@image 已在索引期折进 `e.author`，故建边不再限
    /// paper/book —— 作者页反向"作品"补全 talk/image，QUA-218 规则①收口）；
    /// `worksByAuthorKey` 仍仅 paper/book（siblings 语义限定不变）。
    /// 规则③读 `schema.pathReferences`；边忠实指向目标，章→书上卷见 relations()。
    public static func build(_ entries: [Entry], schema: VaultSchema = .builtin) -> RelationGraph {
        var edges: [Edge] = []
        var works: [String: [Entry]] = [:]
        var byPath: [String: Entry] = [:]
        for e in entries where byPath[e.path] == nil { byPath[e.path] = e }
        let authorPageIndex = NameResolver.AuthorPageIndex(entries)
        let journalPageIndex = NameResolver.JournalPageIndex(entries)
        // slug → 该专题的代表页（first-by-path = overview）；inTopic 边的 to 锚点。
        var topicPageBySlug: [String: Entry] = [:]
        for e in entries where e.type == .topic {
            guard let slug = topicSlug(e.path) else { continue }
            if let cur = topicPageBySlug[slug] {
                if e.path < cur.path { topicPageBySlug[slug] = e }
            } else {
                topicPageBySlug[slug] = e
            }
        }

        for e in entries {
            // 规则①实体引用（反向入图）：author / journal / topic 同构。
            for (i, name) in e.author.enumerated() {
                for page in authorPageIndex.pages(named: name) {
                    edges.append(Edge(from: e.path, kind: .authoredBy, to: page.path, position: i))
                }
            }
            if let journal = nonEmptyField(e.journal) ?? nonEmptyField(e.source),
               let page = journalPageIndex.firstPage(matching: journal) {
                edges.append(Edge(from: e.path, kind: .inJournal, to: page.path))
            }
            for slug in e.topics where !slug.isEmpty {
                if let page = topicPageBySlug[slug] {
                    edges.append(Edge(from: e.path, kind: .inTopic, to: page.path))
                }
            }
            if e.type == .paper || e.type == .book {
                for name in e.author {
                    works[name.lowercased(), default: []].append(e)
                }
            }
            for ref in schema.pathReferences where ref.onType == e.type.rawValue {
                guard let kind = RelationKind(rawValue: ref.kind),
                      let target = pathFieldValue(ref.field, in: e), !target.isEmpty
                else { continue }
                edges.append(Edge(from: e.path, kind: kind, to: target))
            }
        }
        return RelationGraph(edges: edges, worksByAuthorKey: works, entriesByPath: byPath)
    }

    /// 规则③字段名 → Entry 上承载路径引用的强类型属性。Entry 保持强类型
    /// （spec §5 诚实边界），故字段名→属性是一处有名字的映射，与
    /// VaultConformance.isPresent 同理。未建模为路径载体的字段名 → nil（不建边）。
    private static func pathFieldValue(_ field: String, in entry: Entry) -> String? {
        switch field {
        case "annotates": return entry.annotates
        default:          return nil
        }
    }

    private static func nonEmptyField(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}
