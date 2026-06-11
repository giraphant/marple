import Foundation

/// L2 编目层的派生状态 owner（QUA-218 PR3a）。图书馆目录隐喻：从馆藏（vault）
/// 派生、可随时重编、多路检索、带交叉引用。本期持有派生缓存 + vault-变更管线
/// 的统一 generation/单飞权威；entries 与 index 管线过渡期仍在 AppModel。
@MainActor
@Observable
public final class Catalog {
    // 索引派生（entries 变即重算）
    public var themeIndex: [ThemeCount] = []

    public init() {}
}
