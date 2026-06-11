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

    /// 获胜层级的全部匹配作者页（文档序）。第一级 = 旧 AppModel.authorProfile
    /// 扫描（name 小写+trim vs title 小写；RelationsIndex 内联扫描同形但不
    /// trim——两者本就不一致，统一取 trim 形，严格扩大命中）；第二级 =
    /// foldedKey 相等。返回"全部"而非首个：RelationGraph 对同名多页全连边
    /// 以保持旧的按-title-键查询语义。
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

    /// authorPages 的批量形式：建一次两级字典，逐名查询 O(1)。
    /// 语义与 authorPages(named:in:) 逐字相同（exact 层未命中才看 folded 层；
    /// 文档序保留）。RelationGraph.build 用它避免 O(作品×作者名×全库) 扫描。
    struct AuthorPageIndex {
        private let exact: [String: [Entry]]    // key = title.lowercased()
        private let folded: [String: [Entry]]   // key = foldedKey(title)

        init(_ entries: [Entry]) {
            var e: [String: [Entry]] = [:], f: [String: [Entry]] = [:]
            for entry in entries where entry.type == .author {
                let title = entry.title ?? ""
                e[title.lowercased(), default: []].append(entry)
                let fk = NameResolver.foldedKey(title)
                if !fk.isEmpty { f[fk, default: []].append(entry) }
            }
            exact = e; folded = f
        }

        func pages(named name: String) -> [Entry] {
            let key = name.lowercased().trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return [] }
            if let hit = exact[key], !hit.isEmpty { return hit }
            let fk = NameResolver.foldedKey(name)
            guard !fk.isEmpty else { return [] }
            return folded[fk] ?? []
        }
    }

    // MARK: - wikilink

    /// [[target]] → 条目。第一级逐字 = 旧 WikiResolver.resolve（小写 title
    /// 全等 → 小写文件名 stem 全等，均不 trim）；中间补"按 vault 相对路径"层，
    /// 让 `[[papers/x|label]]` 这类带目录前缀的路径形命中（QUA-225）——只有当
    /// needle 带 `/` 时才触发，纯 stem/title 形不受影响；第二级同链 folded。
    public static func resolveWikilink(_ target: String, in entries: [Entry]) -> Entry? {
        let needle = target.lowercased()
        if let byTitle = entries.first(where: { ($0.title ?? "").lowercased() == needle }) {
            return byTitle
        }
        if let byStem = entries.first(where: { fileStem($0.path).lowercased() == needle }) {
            return byStem
        }
        if needle.contains("/") {
            let pathNeedle = needle.hasSuffix(".md") ? String(needle.dropLast(3)) : needle
            if let byPath = entries.first(where: { vaultRelPath($0.path).lowercased() == pathNeedle }) {
                return byPath
            }
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
            return !needle.isDisjoint(with: pageKeys(entry))
        }
    }

    /// 期刊页全部匹配键（journal / title / 路径 slug / 文件名 stem）。
    private static func pageKeys(_ entry: Entry) -> Set<String> {
        journalKeys(entry.journal)
            .union(journalKeys(entry.title))
            .union(journalKeys(journalSlug(entry.path)))
            .union(journalKeys(fileStem(entry.path)))
    }

    /// journalEntry 的批量形式：建一次 key→页 字典，逐论文 O(键数) 查询。
    /// 保留 `journalEntry` 的 first-by-document-order 语义（跨键命中取文档序最早页）。
    /// RelationGraph.build 用它避免 O(论文×全库) 扫描。
    struct JournalPageIndex {
        private let byKey: [String: [(idx: Int, entry: Entry)]]

        init(_ entries: [Entry]) {
            var m: [String: [(Int, Entry)]] = [:]
            for (i, e) in entries.enumerated() where e.type == .journal {
                for k in NameResolver.pageKeys(e) { m[k, default: []].append((i, e)) }
            }
            byKey = m
        }

        func firstPage(matching value: String) -> Entry? {
            let needle = NameResolver.journalKeys(value)
            guard !needle.isEmpty else { return nil }
            var best: (idx: Int, entry: Entry)?
            for k in needle {
                for cand in byKey[k] ?? [] where best == nil || cand.idx < best!.idx {
                    best = cand
                }
            }
            return best?.entry
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

    /// Vault-relative directory path minus the `vault/` prefix and `.md` suffix,
    /// e.g. `vault/papers/foo.md` → `papers/foo`. The match target for path-form
    /// wikilinks (QUA-225).
    private static func vaultRelPath(_ rel: String) -> String {
        var p = rel
        if p.hasPrefix("vault/") { p.removeFirst("vault/".count) }
        if p.hasSuffix(".md") { p.removeLast(3) }
        return p
    }

    private static func journalKeys(_ value: String?) -> Set<String> {
        guard let key = normalizedJournalKey(value) else { return [] }
        var keys: Set<String> = [key]
        let slug = slugKey(key)
        if !slug.isEmpty { keys.insert(slug) }
        return keys
    }

    /// 与 foldedKey 同语义但刻意不共享实现：journal 匹配器逐字保留（verbatim
    /// port 纪律），避免日后一处微调悄悄改动另一处语义。
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
