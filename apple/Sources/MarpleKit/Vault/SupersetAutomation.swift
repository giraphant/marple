import Foundation

// Reader actions are high-level shortcuts over Quasi worker capabilities, not separate workflows.
public enum SupersetAction: String, CaseIterable, Sendable, Equatable {
    case reanalyze
    case format

    public var label: String {
        switch self {
        case .reanalyze: return "重新分析"
        case .format: return "格式整理"
        }
    }

    public var defaultPromptIntent: String {
        switch self {
        case .reanalyze:
            return """
            当前目标文件的分析质量需要重新处理。请先阅读上下文包，再按 Quasi 既有分析能力路由：paper / chapter 类分析文件优先使用 analyse-agent 的规范重新分析；book overview、author profile、topic synthesis 或其他综合型页面优先使用 synthesis-agent 的相应规范重新综合。可以重写目标文件，但不要创建与当前任务无关的文件；保留并修正符合 Quasi schema 的 frontmatter；不要编造不存在的文献、DOI、页码、引文或事实。
            """
        case .format:
            return """
            当前目标文件需要做规范检查与格式整理。请优先调用 Quasi 的 audit 能力处理目标文件，例如 audit-agent 或 quasi-audit --path {{target_relative_path}}。只做 audit 语义下的局部最小修复，包括 frontmatter/schema、标题层级、必需小节、metadata 与机械格式问题；不要重新分析正文，不要扩写观点，不要新增无依据内容。
            """
        }
    }
}

public struct SupersetDispatchConfig: Sendable, Equatable {
    public let workspaceID: String
    public let agent: String
    public let cliPath: String
    public let reanalyzePrompt: String?
    public let formatPrompt: String?

    public init(
        workspaceID: String,
        agent: String = "claude",
        cliPath: String = "superset",
        reanalyzePrompt: String? = nil,
        formatPrompt: String? = nil
    ) {
        self.workspaceID = workspaceID
        self.agent = agent
        self.cliPath = cliPath
        self.reanalyzePrompt = reanalyzePrompt
        self.formatPrompt = formatPrompt
    }

    public func promptIntent(for action: SupersetAction) -> String {
        let customPrompt = switch action {
        case .reanalyze: reanalyzePrompt
        case .format: formatPrompt
        }
        let trimmed = customPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? action.defaultPromptIntent : trimmed
    }
}

public struct SupersetRelatedEntry: Sendable, Equatable {
    public let path: String
    public let type: String
    public let title: String?
    public let summary: String?
    public let reason: String

    public init(path: String, type: String, title: String?, summary: String?, reason: String) {
        self.path = path
        self.type = type
        self.title = title
        self.summary = summary
        self.reason = reason
    }

    public init(entry: Entry, reason: String) {
        let trimmedPreview = entry.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        self.path = entry.path
        self.type = entry.type.rawValue
        self.title = entry.title
        self.summary = trimmedPreview.isEmpty ? nil : trimmedPreview
        self.reason = reason
    }
}

public struct SupersetWikiTarget: Sendable, Equatable {
    public let target: String
    public let label: String
    public let path: String
    public let title: String?

    public init(target: String, label: String, path: String, title: String?) {
        self.target = target
        self.label = label
        self.path = path
        self.title = title
    }
}

public struct SupersetRelatedContext: Sendable, Equatable {
    public let annotations: [SupersetRelatedEntry]
    public let bookEntries: [SupersetRelatedEntry]
    public let relatedWorks: [SupersetRelatedEntry]
    public let wikilinks: [SupersetWikiTarget]
    public let sourcePaths: [String]

    public init(
        annotations: [SupersetRelatedEntry] = [],
        bookEntries: [SupersetRelatedEntry] = [],
        relatedWorks: [SupersetRelatedEntry] = [],
        wikilinks: [SupersetWikiTarget] = [],
        sourcePaths: [String] = []
    ) {
        self.annotations = annotations
        self.bookEntries = bookEntries
        self.relatedWorks = relatedWorks
        self.wikilinks = wikilinks
        self.sourcePaths = sourcePaths
    }
}

public enum SupersetContextError: Error, Equatable {
    case absoluteTargetPath
    case targetEscapesWorkspace
}

public struct SupersetDispatchContext: Sendable, Equatable {
    public let workspaceRoot: String
    public let targetPath: String
    public let entry: Entry
    public let documentText: String
    public let related: SupersetRelatedContext
    private let resolvedTargetAbsolutePath: String

    public var targetAbsolutePath: String { resolvedTargetAbsolutePath }

    public init(
        workspaceRoot: String,
        targetPath: String,
        entry: Entry,
        documentText: String,
        related: SupersetRelatedContext
    ) throws {
        guard !(targetPath as NSString).isAbsolutePath else {
            throw SupersetContextError.absoluteTargetPath
        }

        let standardizedWorkspaceRoot = URL(fileURLWithPath: workspaceRoot).standardizedFileURL.path
        let standardizedTarget = URL(fileURLWithPath: standardizedWorkspaceRoot)
            .appendingPathComponent(targetPath)
            .standardizedFileURL
            .path
        let workspacePrefix = standardizedWorkspaceRoot.hasSuffix("/") ? standardizedWorkspaceRoot : standardizedWorkspaceRoot + "/"
        guard standardizedTarget == standardizedWorkspaceRoot || standardizedTarget.hasPrefix(workspacePrefix) else {
            throw SupersetContextError.targetEscapesWorkspace
        }

        self.workspaceRoot = workspaceRoot
        self.targetPath = targetPath
        self.entry = entry
        self.documentText = documentText
        self.related = related
        self.resolvedTargetAbsolutePath = standardizedTarget
    }
}

public enum SupersetContextPackageBuilder {
    public static func markdown(for action: SupersetAction, context: SupersetDispatchContext) -> String {
        var lines: [String] = []
        lines.append("# Marple Superset Context")
        lines.append("")
        lines.append("## Action")
        lines.append(action.label)
        lines.append("")
        lines.append("## Target File")
        lines.append("Workspace-relative path: \(context.targetPath)")
        lines.append("Absolute path: \(context.targetAbsolutePath)")
        lines.append("")
        lines.append("Only edit the target file above. Do not edit this context package.")
        lines.append("")
        lines.append("## Entry Metadata")
        lines.append("- Type: \(context.entry.type.rawValue)")
        appendMetadata("Title", context.entry.title, to: &lines)
        appendMetadata("Author", context.entry.author.joined(separator: ", "), to: &lines)
        appendMetadata("Year", context.entry.year, to: &lines)
        lines.append("- Rating: \(context.entry.ratingScore)")
        if !context.entry.themes.isEmpty {
            lines.append("- Themes: \(context.entry.themes.joined(separator: ", "))")
        }
        appendMetadata("Preview", context.entry.preview, to: &lines)
        lines.append("- Has PDF: \(context.entry.hasPDF)")
        appendMetadata("PDF Slug", context.entry.pdfSlug, to: &lines)
        appendMetadata("Source", context.entry.source, to: &lines)
        appendMetadata("Topic", context.entry.topic, to: &lines)
        appendMetadata("DOI", context.entry.doi, to: &lines)
        lines.append("")
        lines.append("## Related Context")
        appendEntries(title: "Annotations", context.related.annotations, to: &lines)
        appendEntries(title: "Book Entries", context.related.bookEntries, to: &lines)
        appendEntries(title: "Related Works", context.related.relatedWorks, to: &lines)
        appendWikilinks(context.related.wikilinks, to: &lines)
        appendSourcePaths(context.related.sourcePaths, to: &lines)
        lines.append("")
        lines.append("## Document Text")
        lines.append(context.documentText)
        lines.append("")
        return lines.joined(separator: "\n")
    }

    public static func write(
        action: SupersetAction,
        context: SupersetDispatchContext,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("marple-superset-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("context.md")
        try markdown(for: action, context: context).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func appendMetadata(_ label: String, _ value: String?, to lines: inout [String]) {
        guard let value, !value.isEmpty else { return }
        lines.append("- \(label): \(value)")
    }

    private static func appendEntries(title: String, _ entries: [SupersetRelatedEntry], to lines: inout [String]) {
        lines.append("### \(title)")
        if entries.isEmpty {
            lines.append("- None")
        } else {
            for entry in entries {
                var parts = [entry.path]
                if let title = entry.title, !title.isEmpty {
                    parts.append(title)
                }
                parts.append(entry.reason)
                if let summary = entry.summary, !summary.isEmpty {
                    parts.append(summary)
                }
                lines.append("- \(parts.joined(separator: " — "))")
            }
        }
        lines.append("")
    }

    private static func appendWikilinks(_ wikilinks: [SupersetWikiTarget], to lines: inout [String]) {
        lines.append("### Wikilinks")
        if wikilinks.isEmpty {
            lines.append("- None")
        } else {
            for wikilink in wikilinks {
                if let title = wikilink.title, !title.isEmpty {
                    lines.append("- [[\(wikilink.label)]] -> \(wikilink.path) — \(title)")
                } else {
                    lines.append("- [[\(wikilink.label)]] -> \(wikilink.path)")
                }
            }
        }
        lines.append("")
    }

    private static func appendSourcePaths(_ sourcePaths: [String], to lines: inout [String]) {
        lines.append("### Source Paths")
        if sourcePaths.isEmpty {
            lines.append("- None")
        } else {
            for path in sourcePaths {
                lines.append("- \(path)")
            }
        }
    }
}

public enum SupersetPromptBuilder {
    public static func prompt(
        action: SupersetAction,
        targetRelativePath: String,
        targetAbsolutePath: String,
        contextPackagePath: String,
        promptIntent: String? = nil
    ) -> String {
        let renderedIntent = renderTemplate(
            promptIntent ?? action.defaultPromptIntent,
            action: action,
            targetRelativePath: targetRelativePath,
            targetAbsolutePath: targetAbsolutePath,
            contextPackagePath: contextPackagePath
        )
        return """
        请执行 Marple Superset 动作：\(action.label)

        目标文件（工作区相对路径）：\(targetRelativePath)
        目标文件（绝对路径）：\(targetAbsolutePath)
        上下文包：\(contextPackagePath)

        \(renderedIntent)

        请先阅读上下文包。只编辑目标文件，不要编辑上下文包或其他文件。
        """
    }

    public static func renderTemplate(
        _ template: String,
        action: SupersetAction,
        targetRelativePath: String,
        targetAbsolutePath: String,
        contextPackagePath: String
    ) -> String {
        template
            .replacingOccurrences(of: "{{action}}", with: action.label)
            .replacingOccurrences(of: "{{target_relative_path}}", with: targetRelativePath)
            .replacingOccurrences(of: "{{target_absolute_path}}", with: targetAbsolutePath)
            .replacingOccurrences(of: "{{context_package_path}}", with: contextPackagePath)
    }
}
