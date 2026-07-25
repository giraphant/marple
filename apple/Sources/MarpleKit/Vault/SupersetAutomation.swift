import Foundation

// Reader actions are high-level shortcuts over Quasi worker capabilities, not separate workflows.
public enum SupersetAction: String, CaseIterable, Sendable, Equatable {
    case reanalyze
    case format
    case translate
    case discuss

    public var label: String {
        switch self {
        case .reanalyze: return "重新分析"
        case .format: return "格式整理"
        case .translate: return "制作译本"
        case .discuss: return "对话讨论"
        }
    }

    public var defaultPromptIntent: String {
        switch self {
        case .reanalyze: return ReaderAIPrompts.reanalyze
        case .format: return ReaderAIPrompts.formatAudit
        case .translate: return ReaderAIPrompts.translatePDF
        case .discuss: return ReaderAIPrompts.discuss
        }
    }

    var finalBoundary: String {
        switch self {
        case .reanalyze:
            return ReaderAIPrompts.reanalysisBoundary
        case .discuss:
            return ReaderAIPrompts.discussionBoundary
        case .format, .translate:
            return ReaderAIPrompts.targetEditBoundary
        }
    }

    var contextBoundary: String {
        switch self {
        case .reanalyze:
            return ReaderAIPrompts.contextReanalysisBoundary
        case .discuss:
            return ReaderAIPrompts.contextDiscussionBoundary
        case .format, .translate:
            return ReaderAIPrompts.contextTargetEditBoundary
        }
    }

    var requiredGuardrail: String? {
        switch self {
        case .format:
            return ReaderAIPrompts.auditGuardrail
        case .reanalyze, .translate, .discuss:
            return nil
        }
    }
}

/// Where AI actions get dispatched. Each preset is only a default command
/// template — the template is the real mechanism, the picker just pre-fills it,
/// so any terminal/agent combo is reachable by editing the template.
public enum AIDispatchTarget: String, CaseIterable, Sendable {
    case superset
    case orca
    case otty
    case terminal
    case custom

    public var label: String {
        switch self {
        case .superset: return "Superset"
        case .orca: return "Orca"
        case .otty: return "Otty"
        case .terminal: return "终端 (Terminal)"
        case .custom: return "自定义"
        }
    }

    /// Templates run through `zsh -lc` with `MARPLE_*` variables exported (see
    /// `SupersetRunner.dispatch`). Terminal-style targets open the generated
    /// `$MARPLE_RUN_SCRIPT` (.command), so any app that can run a shell script works.
    public var defaultTemplate: String {
        switch self {
        case .superset:
            // $MARPLE_SUPERSET_CLI carries the (resolved) CLI 路径 setting, so
            // legacy installs pointing at a custom binary keep working.
            return #""$MARPLE_SUPERSET_CLI" agents create --workspace "$MARPLE_WORKSPACE" --agent "$MARPLE_AGENT" --prompt "$(cat "$MARPLE_PROMPT_FILE")" --attachment "$MARPLE_CONTEXT_FILE""#
        case .orca:
            return #"orca terminal create --worktree "path:$MARPLE_VAULT_ROOT" --title "$MARPLE_TITLE" --command "$MARPLE_RUN_SCRIPT" --focus"#
        case .otty:
            return #"open -a Otty "$MARPLE_RUN_SCRIPT""#
        case .terminal:
            return #"open -a Terminal "$MARPLE_RUN_SCRIPT""#
        case .custom:
            return ""
        }
    }

    /// Resolves the effective dispatch template from the stored settings.
    /// Unset/blank stored template falls back to the selected preset's default,
    /// so legacy installs (nothing stored) keep the Superset flow unchanged.
    public static func resolveTemplate(targetRawValue: String?, storedTemplate: String?) -> String {
        let target = AIDispatchTarget(rawValue: targetRawValue ?? "") ?? .superset
        let stored = (storedTemplate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return stored.isEmpty ? target.defaultTemplate : stored
    }
}

public struct SupersetDispatchConfig: Sendable, Equatable {
    public let workspaceID: String
    public let agent: String
    public let cliPath: String
    public let commandTemplate: String
    public let reanalyzePrompt: String?
    public let formatPrompt: String?
    public let translatePrompt: String?
    public let discussPrompt: String?

    public init(
        workspaceID: String,
        agent: String = "claude",
        cliPath: String = "superset",
        commandTemplate: String = AIDispatchTarget.superset.defaultTemplate,
        reanalyzePrompt: String? = nil,
        formatPrompt: String? = nil,
        translatePrompt: String? = nil,
        discussPrompt: String? = nil
    ) {
        self.workspaceID = workspaceID
        self.agent = agent
        self.cliPath = cliPath
        self.commandTemplate = commandTemplate
        self.reanalyzePrompt = reanalyzePrompt
        self.formatPrompt = formatPrompt
        self.translatePrompt = translatePrompt
        self.discussPrompt = discussPrompt
    }

    public func promptIntent(for action: SupersetAction) -> String {
        let customPrompt = switch action {
        case .reanalyze: reanalyzePrompt
        case .format: formatPrompt
        case .translate: translatePrompt
        case .discuss: discussPrompt
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
        lines.append("# Marple Context")
        lines.append("")
        lines.append("## Action")
        lines.append(action.label)
        lines.append("")
        lines.append("## Target File")
        lines.append("Workspace-relative path: \(context.targetPath)")
        lines.append("Absolute path: \(context.targetAbsolutePath)")
        lines.append("")
        lines.append(action.contextBoundary)
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
        if !context.entry.topics.isEmpty {
            lines.append("- Topics: \(context.entry.topics.joined(separator: ", "))")
        }
        appendMetadata("Preview", context.entry.preview, to: &lines)
        lines.append("- Has PDF: \(context.entry.hasPDF)")
        appendMetadata("PDF Slug", context.entry.pdfSlug, to: &lines)
        appendMetadata("Source", context.entry.source, to: &lines)
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
        let renderedGuardrail = action.requiredGuardrail.map {
            renderTemplate(
                $0,
                action: action,
                targetRelativePath: targetRelativePath,
                targetAbsolutePath: targetAbsolutePath,
                contextPackagePath: contextPackagePath
            )
        }
        let guardrailBlock = renderedGuardrail.map { "\n\n\($0)" } ?? ""
        return """
        请执行 Marple 动作：\(action.label)

        目标文件（工作区相对路径）：\(targetRelativePath)
        目标文件（绝对路径）：\(targetAbsolutePath)
        上下文包：\(contextPackagePath)

        \(renderedIntent)\(guardrailBlock)

        \(action.finalBoundary)
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
