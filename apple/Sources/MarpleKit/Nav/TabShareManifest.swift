import Foundation

/// One node in a share manifest: a tab leaf or a (recursive) group. Built by
/// `AppModel` from the sidebar 页面 forest and rendered to Markdown that is both
/// human-readable and LLM-friendly. Carries no document content — only the tab's
/// name, original title and absolute file path.
public enum TabShareNode: Sendable, Equatable {
    /// `name` is the user's custom tab title (nil when never renamed). `title` is the
    /// document's own title. `absolutePath` is nil for non-document tabs (browse panes).
    case tab(name: String?, title: String, absolutePath: String?)
    case group(name: String, children: [TabShareNode])
}

/// Render the clicked node(s) as a Markdown manifest.
///
/// - A top-level group becomes an `# H1` followed by a nested bullet list of its
///   children, mirroring the folder structure to any depth.
/// - A top-level tab becomes a single bullet, no header.
public func renderTabShareManifest(_ roots: [TabShareNode]) -> String {
    var lines: [String] = []
    for root in roots {
        switch root {
        case .group(let name, let children):
            lines.append("# \(name)")
            lines.append("")
            lines.append(contentsOf: renderShareList(children, indent: 0))
        case .tab:
            lines.append(contentsOf: renderShareList([root], indent: 0))
        }
    }
    return lines.joined(separator: "\n")
}

private func renderShareList(_ nodes: [TabShareNode], indent: Int) -> [String] {
    let pad = String(repeating: "  ", count: indent)
    var out: [String] = []
    for node in nodes {
        switch node {
        case .tab(let name, let title, let path):
            out.append(pad + "- " + shareTabLabel(name: name, title: title, path: path))
        case .group(let name, let children):
            out.append(pad + "- \(name)/")
            out.append(contentsOf: renderShareList(children, indent: indent + 1))
        }
    }
    return out
}

/// `**custom name** — *original title* — `path`` when a custom name differs from the
/// title; otherwise `**title** — `path``. The path clause is dropped for non-document tabs.
private func shareTabLabel(name: String?, title: String, path: String?) -> String {
    var label: String
    if let name, name != title {
        label = "**\(name)** — *\(title)*"
    } else {
        label = "**\(title)**"
    }
    if let path {
        label += " — `\(path)`"
    }
    return label
}
