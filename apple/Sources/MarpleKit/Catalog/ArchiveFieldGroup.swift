import Foundation

/// Display-only groups. The IDs cannot be mistaken for vault file paths.
public struct ArchiveFieldGroup: Equatable, Sendable, Identifiable {
    public let field: String
    public let value: String?
    public let members: [String]
    public var id: String {
        let key = Data(field.utf8).base64EncodedString()
        let value = value.map { Data($0.utf8).base64EncodedString() } ?? "-"
        return "marple-group:\(key):\(value)"
    }
    public var path: String { id }
    public var title: String { value ?? String(localized: "未填写") }
    public var entryPath: String { id + "/collection.md" }

    public static func values(_ value: YamlValue) -> [String] {
        let items: [YamlValue]
        if case .sequence(let list) = value { items = list } else { items = [value] }
        var seen = Set<String>()
        return items.compactMap { item -> String? in
            switch item {
            case .null, .mapping, .sequence: return nil
            default: return textValue(item)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public static func groups(paths: [String], fields: [String: [String: [String]]], by field: String) -> [Self] {
        var groups: [String: [String]] = [:], missing: [String] = []
        var seen = Set<String>()
        for path in paths where seen.insert(path).inserted {
            let values = fields[path]?[field] ?? []
            if values.isEmpty { missing.append(path) }
            for value in values { groups[value, default: []].append(path) }
        }
        var result = groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { Self(field: field, value: $0, members: groups[$0]!) }
        if !missing.isEmpty { result.append(Self(field: field, value: nil, members: missing)) }
        return result
    }
}
