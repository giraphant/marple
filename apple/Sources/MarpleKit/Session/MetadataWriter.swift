import Foundation

/// frontmatter 写回的写穿 IO 边界（QUA-218 PR3b L4 下沉）。
/// 拥有"取最新磁盘文本 → 应用变换 → 原子写回"契约；字段语义（FrontmatterPatch
/// 组合）+ 乐观内存更新留在壳的 applyPatch（耦合 entries/UI 态，过渡期留壳）。
/// iOS 只读是产品选择而非平台限制——能力下沉、闲置零成本。
///
/// Lives in MarpleKit so the iOS reader could call it if it ever gains write
/// capability — capability sinks down, idle at zero cost (mirrors SessionWriter).
public struct MetadataWriter: Sendable {
    private let client: VaultClient
    public init(client: VaultClient) { self.client = client }

    /// 取 path 的最新文本，过 transform，写回。任何 IO 失败原样抛出（壳 catch）。
    /// @MainActor because `transform` is a synchronous closure captured from
    /// @MainActor-isolated call sites (it touches `entries`/UI bindings); running it
    /// on the main actor preserves the pre-image's exact execution — only the
    /// entryText/writeFile awaits hop to the client's executor.
    @MainActor
    public func write(path: String, applying transform: (String) -> String) async throws {
        let fresh = try await client.entryText(path: path)
        try await client.writeFile(path: path, text: transform(fresh))
    }
}
