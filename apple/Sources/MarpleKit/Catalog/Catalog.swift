import Foundation

/// L2 编目层的状态 owner（QUA-218 PR3a / QUA-229）。图书馆目录隐喻：从馆藏（vault）
/// 派生、可随时重编、多路检索、带交叉引用。持有 `entries` 源快照 + 全部派生缓存 +
/// vault-变更管线的统一 generation/单飞权威。`entries` 经 `publish`（陈旧守卫）/
/// `mutateEntries`（乐观编辑）改；reconcile 编排与 post-publish 反应仍由各壳供给——
/// 平台分叉决定的终态,见 ARCHITECTURE.md「下沉边界」,非过渡欠债。
///
/// Stored properties live here in the primary declaration (the `@Observable`
/// macro only sees properties declared in the class body, not extensions). The
/// recompute / refresh methods are split into `Catalog+*` extension files by
/// concern (index-derived / deferred-derived / visible+search / open-doc /
/// refresh authority); this file holds ONLY state + init + bootstrap seeding.
@MainActor
@Observable
public final class Catalog {
    /// 全库 entries 快照 —— L2 派生层的**源**数据 owner（QUA-229：从两壳的中枢
    /// view-model 下沉至此，让 Catalog 真正拥有它派生所依赖的源，而非只持派生）。
    /// `internal(set)`：壳无法直接赋值，只能经 `publish`/`mutateEntries` 改（核内
    /// 唯一权威）；壳侧以 `var entries { catalog.entries }` facade 只读转发，所有
    /// 读 `model.entries` 的视图调用点不变。
    public internal(set) var entries: [Entry] = []

    // 索引派生（entries 变即重算）
    public internal(set) var counts: [EntryType: Int] = [:]
    public internal(set) var savedViewCounts: [UUID: Int] = [:]
    public internal(set) var topicMembership: TopicMembership = TopicMembership()
    public internal(set) var themeIndex: [ThemeCount] = []

    // deferred 派生（entries 变更后台重算）
    public internal(set) var relationGraph: RelationGraph = .empty
    public internal(set) var searchIndex: SearchIndex = .empty
    /// 派生就绪回调（过渡期）：deferred 派生发布后,若有开档则重算开档派生。
    /// Task 5 把 recomputeOpenDerived 迁入后改为内部直调。
    public var onDerivedReady: (() -> Void)?
    var deferredDerivedTask: Task<Void, Never>?
    // Independent of `pass` (Decision 1): bumped by every scheduleDeferredDerivedRebuild
    // incl. optimistic edits; do NOT fold into pass.
    var derivedGeneration: Int = 0

    // 可见列表 + 列表搜索匹配缓存（QUA-218 PR3a Task 4）
    public internal(set) var visibleEntries: [Entry] = []
    /// Per-result matched body lines for the current list search (keyed by path).
    /// Populated off-main after the search settles; rows read from it.
    public internal(set) var searchMatches: [String: BodyMatches] = [:]
    /// The query `searchMatches` was computed for. A matched-line tap uses THIS
    /// (not the live `searchText`) so a tap during the debounce window stays
    /// self-consistent — anchor/ordinal/query always describe the same search.
    public internal(set) var searchMatchQuery: String = ""
    /// Result rows whose "再显示 N 个匹配项" expander has been opened.
    public var matchExpanded: Set<String> = []
    /// filter/sort 防抖轴（独立，不并入统一 generation）
    var recomputeTask: Task<Void, Never>?
    /// 搜索匹配加载防抖轴（独立，不并入统一 generation）
    var matchTask: Task<Void, Never>?

    // 开档派生缓存（open / reload / metadata 写时重算，非每帧）（QUA-218 PR3a Task 5）
    public internal(set) var openEntry: Entry?
    public internal(set) var openOutline: [OutlineItem] = []
    public internal(set) var openStats: DocStats?
    public internal(set) var openRelations: Relations?
    public internal(set) var openBook: BookContext?
    public internal(set) var openTopic: TopicContext?

    // MARK: - 统一刷新权威 (QUA-218 PR3a Task 7)
    // vault-变更管线的唯一 generation/单飞：RefreshAuthority（合流单飞，QUA-198 OOM
    // 承重墙）+ per-pass `pass`（旧 loadIndexGeneration 的 staleness）2→1 统一。
    // derivedGeneration 保持独立（决策 1：它有乐观单条编辑这条 refresh 之外的触发
    // 轴，折叠会引入派生覆盖竞态）。方法体见 Catalog+Refresh.swift。
    let authority = RefreshAuthority()
    /// 唯一 per-pass generation：服务 loadIndex 管线陈旧丢弃。每个 refresh body 跑一次
    /// bump 一次。NOT for derive (决策 1)。`internal(set)` so the refresh methods in
    /// `Catalog+Refresh.swift` (a separate file) can bump it; public read unchanged.
    public internal(set) var pass: Int = 0

    public init() {}

    /// Bootstrap-only: seed counts from persisted state in AppModel.init BEFORE
    /// the first rebuildIndexDerived. Calling it afterwards overwrites live counts
    /// with stale restored data. Not a general setter.
    public func seedCounts(_ restored: [EntryType: Int]) { counts = restored }
}
