import Foundation

/// 全库唯一的名字归一/匹配器（QUA-218 规则①的解析端）。
///
/// 统一结构：每个匹配器的第一级**逐字保留**它被收拢前的算法（旧命中 winner
/// 永不改变）；第二级共用 `foldedKey`（去变音符 + 空白折叠 + 小写），只在
/// 第一级零命中时兜底。这把归一差异压成"只增不改"——用户已批准的三条新增
/// 命中见 NameResolverTests。journal 匹配器本身就是 folded 规则的来源，
/// 逐字搬入、无第二级。
public enum NameResolver {

    /// 宽松归一键：trim → 去变音符/大小写折叠 → 空白折叠 → 小写。
    /// 与 journal 匹配器的 normalizedJournalKey 同款。
    static func foldedKey(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = trimmed.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return folded
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()
    }

    // MARK: - 作者页

    /// 获胜层级的全部匹配作者页（文档序）。第一级 = 旧 RelationsIndex 扫描
    /// （name 小写+trim vs title 小写）；第二级 = foldedKey 相等。
    /// 返回"全部"而非首个：RelationGraph 对同名多页全连边以保持旧的
    /// 按-title-键查询语义。
    public static func authorPages(named name: String, in entries: [Entry]) -> [Entry] {
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return [] }
        let exact = entries.filter { $0.type == .author && ($0.title ?? "").lowercased() == key }
        if !exact.isEmpty { return exact }
        let folded = foldedKey(name)
        guard !folded.isEmpty else { return [] }
        return entries.filter { $0.type == .author && foldedKey($0.title ?? "") == folded }
    }

    /// 首个匹配作者页（= 旧 entries.first 扫描，外加批准的 folded 兜底）。
    public static func authorProfile(named name: String, in entries: [Entry]) -> Entry? {
        authorPages(named: name, in: entries).first
    }

    // MARK: - wikilink

    /// [[target]] → 条目。第一级逐字 = 旧 WikiResolver.resolve（小写 title
    /// 全等 → 小写文件名 stem 全等，均不 trim）；第二级同链 folded。
    public static func resolveWikilink(_ target: String, in entries: [Entry]) -> Entry? {
        let needle = target.lowercased()
        if let byTitle = entries.first(where: { ($0.title ?? "").lowercased() == needle }) {
            return byTitle
        }
        if let byStem = entries.first(where: { fileStem($0.path).lowercased() == needle }) {
            return byStem
        }
        let folded = foldedKey(target)
        guard !folded.isEmpty else { return nil }
        if let byTitle = entries.first(where: { foldedKey($0.title ?? "") == folded }) {
            return byTitle
        }
        return entries.first { foldedKey(fileStem($0.path)) == folded }
    }

    // MARK: - journal（逐字搬自 InspectorMetadataRows，QUA-218 收拢进 Kit）

    public static func journalEntry(matching value: String, in entries: [Entry]) -> Entry? {
        let needle = journalKeys(value)
        guard !needle.isEmpty else { return nil }
        return entries.first { entry in
            guard entry.type == .journal else { return false }
            let keys = journalKeys(entry.journal)
                .union(journalKeys(entry.title))
                .union(journalKeys(journalSlug(entry.path)))
                .union(journalKeys(fileStem(entry.path)))
            return !needle.isDisjoint(with: keys)
        }
    }

    private static func journalSlug(_ rel: String) -> String? {
        guard rel.hasPrefix("vault/journals/") else { return nil }
        let rest = String(rel.dropFirst("vault/journals/".count))
        guard let first = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first else {
            return nil
        }
        return String(first).replacingOccurrences(of: ".md", with: "")
    }

    private static func fileStem(_ rel: String) -> String {
        (rel as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
    }

    private static func journalKeys(_ value: String?) -> Set<String> {
        guard let key = normalizedJournalKey(value) else { return [] }
        var keys: Set<String> = [key]
        let slug = slugKey(key)
        if !slug.isEmpty { keys.insert(slug) }
        return keys
    }

    private static func normalizedJournalKey(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        let folded = trimmed.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let collapsed = folded.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return collapsed.lowercased()
    }

    private static func slugKey(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
