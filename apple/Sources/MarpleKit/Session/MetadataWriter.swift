import Foundation

/// frontmatter 写回的写穿 IO 边界（QUA-218 PR3b L4 下沉）。
/// 拥有"取最新磁盘文本 → 应用变换 → 原子写回"契约；字段语义（FrontmatterPatch
/// 组合）+ 乐观内存更新留在壳的 applyPatch（耦合 entries/UI 态，过渡期留壳）。
/// iOS 只读是产品选择而非平台限制——能力下沉、闲置零成本。
public struct MetadataWriter: Sendable {
    private let client: VaultClient
    public init(client: VaultClient) { self.client = client }

    /// 取 path 的最新文本，过 transform，写回。任何 IO 失败原样抛出（壳 catch）。
    /// 整法 @MainActor：壳的 patch 是主 actor 闭包；逐字保持旧 applyPatch 里
    /// `patch(fresh)` 在主 actor 上同步执行的语义（IO 的 await 照常跳客户端执行器）。
    @MainActor
    public func write(path: String, applying transform: (String) -> String) async throws {
        let fresh = try await client.entryText(path: path)
        try await client.writeFile(path: path, text: transform(fresh))
    }
}
