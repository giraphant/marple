import Foundation

/// Serialize a `VaultSchema` back to `vault/schema/schema.yaml` as a *minimal
/// override* of `.builtin` (QUA-222 UI editor). Only entities / displays /
/// pathReferences that differ from builtin are emitted, so the on-disk file
/// stays small and every untouched key keeps tracking future builtin changes.
/// The output round-trips through `applying(overrides:)` — see VaultSchemaTests.
public extension VaultSchema {

    /// The override YAML body. Empty (header-only) when `self == .builtin`.
    ///
    /// Granularity mirrors `applying(overrides:)`: an entity's `fields` list and a
    /// type's `{symbol, tint}` are replaced wholesale, `pathReferences` is one
    /// whole list. Two cases the override format cannot express (and the editor
    /// therefore disallows): an entity with *zero* fields and an *empty*
    /// `pathReferences` list — both are ignored on load, reverting to builtin.
    func overrideYAML() -> String {
        var out =
            "# vault/schema/schema.yaml — Marple 声明表覆盖（设置面板生成）\n" +
            "# 只记录与内置默认不同的项；删掉本文件即可全部恢复默认。\n"

        var entityLines: [String] = []
        for key in entityAliases.keys.sorted() {
            let aliases = entityAliases[key] ?? []
            guard !aliases.isEmpty, VaultSchema.builtin.entityAliases[key] != aliases else { continue }
            entityLines.append("  \(Self.yamlScalar(key)):")
            entityLines.append("    fields:")
            for a in aliases {
                if let t = a.onlyForType {
                    entityLines.append("      - field: \(Self.yamlScalar(a.field))")
                    entityLines.append("        type: \(Self.yamlScalar(t))")
                } else {
                    entityLines.append("      - \(Self.yamlScalar(a.field))")
                }
            }
        }
        if !entityLines.isEmpty {
            out += "\nentities:\n" + entityLines.joined(separator: "\n") + "\n"
        }

        var displayLines: [String] = []
        for key in displayByType.keys.sorted() {
            guard let d = displayByType[key], VaultSchema.builtin.displayByType[key] != d else { continue }
            displayLines.append("  \(Self.yamlScalar(key)):")
            displayLines.append("    symbol: \(Self.yamlScalar(d.symbol))")
            displayLines.append("    tint: \(Self.yamlScalar(d.tint))")
        }
        if !displayLines.isEmpty {
            out += "\ndisplay:\n" + displayLines.joined(separator: "\n") + "\n"
        }

        if !pathReferences.isEmpty, pathReferences != VaultSchema.builtin.pathReferences {
            out += "\npathReferences:\n"
            for r in pathReferences {
                out += "  - onType: \(Self.yamlScalar(r.onType))\n"
                out += "    field: \(Self.yamlScalar(r.field))\n"
                out += "    kind: \(Self.yamlScalar(r.kind))\n"
            }
        }

        return out
    }

    /// Write the override to `<workspaceRoot>/vault/schema/schema.yaml`, creating
    /// the `schema/` directory. When `self == .builtin` (no overrides) the file is
    /// removed instead of left as a dead header — an absent file *is* "all
    /// defaults", and `load` degrades to builtin identically.
    func save(workspaceRoot: String) throws {
        let url = URL(fileURLWithPath: workspaceRoot).appendingPathComponent(Self.relativePath)
        if self == .builtin {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try overrideYAML().write(to: url, atomically: true, encoding: .utf8)
    }

    /// Quote a scalar only when it is not a bare identifier (letters/digits/.-_).
    /// Field names, type rawValues, SF Symbol names and tint names are all bare in
    /// practice; this is the safety net for an odd custom value.
    private static func yamlScalar(_ s: String) -> String {
        let bare = !s.isEmpty && s.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-"
        }
        if bare { return s }
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
