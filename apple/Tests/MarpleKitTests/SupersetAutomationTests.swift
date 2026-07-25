import Foundation
import Testing
@testable import MarpleKit

@Suite struct SupersetAutomationTests {
    private final class LogBox: @unchecked Sendable {
        private(set) var entries: [String] = []
        func append(_ message: String) { entries.append(message) }
    }

    private let entry = Entry(
        path: "vault/papers/a.md",
        type: .paper,
        title: "Paper A",
        author: ["Jane Doe"],
        year: "2025",
        ratingScore: 4,
        themes: ["AI", "workflow"],
        topics: ["agents"],
        preview: "Short preview",
        hasPDF: true,
        pdfSlug: "paper-a",
        source: "Journal X",
        doi: "10.1234/a"
    )

    @Test func contextPackageIncludesTargetMetadataBodyAndBoundary() throws {
        let context = try SupersetDispatchContext(
            workspaceRoot: "/tmp/marple-workspace",
            targetPath: "vault/papers/a.md",
            entry: entry,
            documentText: "---\ntitle: Paper A\n---\n\n# Old analysis",
            related: SupersetRelatedContext()
        )

        let markdown = SupersetContextPackageBuilder.markdown(for: .reanalyze, context: context)

        #expect(markdown.contains("# Marple Superset Context"))
        #expect(markdown.contains("## Action\n重新分析"))
        #expect(markdown.contains("Workspace-relative path: vault/papers/a.md"))
        #expect(markdown.contains("Absolute path: /tmp/marple-workspace/vault/papers/a.md"))
        #expect(markdown.contains("Default to editing the target file above. If reanalysis requires completing the same book, edits may include same-book overview/chapter analysis files only. Do not edit this context package."))
        #expect(markdown.contains("- Type: paper"))
        #expect(markdown.contains("- Title: Paper A"))
        #expect(markdown.contains("- Author: Jane Doe"))
        #expect(markdown.contains("- Themes: AI, workflow"))
        #expect(markdown.contains("# Old analysis"))
    }

    @Test func discussionContextPackageUsesNoEditBoundary() throws {
        let context = try SupersetDispatchContext(
            workspaceRoot: "/tmp/marple-workspace",
            targetPath: "vault/papers/a.md",
            entry: entry,
            documentText: "Body",
            related: SupersetRelatedContext()
        )

        let markdown = SupersetContextPackageBuilder.markdown(for: .discuss, context: context)

        #expect(markdown.contains("## Action\n对话讨论"))
        #expect(markdown.contains("Do not edit, create, or delete files for this discussion action."))
        #expect(!markdown.contains("Only edit the target file above."))
    }

    @Test func contextPackageIncludesRelatedEntriesWikilinksAndSources() throws {
        let annotation = SupersetRelatedEntry(
            path: "vault/notes/a-note.md",
            type: "note",
            title: "My note",
            summary: "Personal annotation",
            reason: "annotation"
        )
        let related = SupersetRelatedContext(
            annotations: [annotation],
            bookEntries: [SupersetRelatedEntry(path: "vault/books/b.md", type: "book", title: "Book B", summary: "Book context", reason: "same book")],
            relatedWorks: [SupersetRelatedEntry(path: "vault/papers/b.md", type: "paper", title: "Paper B", summary: "Related", reason: "shared themes")],
            wikilinks: [SupersetWikiTarget(target: "Concept", label: "Concept", path: "vault/topics/concept.md", title: "Concept")],
            sourcePaths: ["sources/paper-a.pdf", "processing/translations/paper-a-zh.pdf"]
        )
        let context = try SupersetDispatchContext(
            workspaceRoot: "/tmp/marple-workspace",
            targetPath: "vault/papers/a.md",
            entry: entry,
            documentText: "Body with [[Concept]]",
            related: related
        )

        let markdown = SupersetContextPackageBuilder.markdown(for: .format, context: context)

        #expect(markdown.contains("## Action\n格式整理"))
        #expect(markdown.contains("vault/notes/a-note.md — My note — annotation — Personal annotation"))
        #expect(markdown.contains("vault/books/b.md — Book B — same book — Book context"))
        #expect(markdown.contains("vault/papers/b.md — Paper B — shared themes — Related"))
        #expect(markdown.contains("[[Concept]] -> vault/topics/concept.md — Concept"))
        #expect(markdown.contains("sources/paper-a.pdf"))
        #expect(markdown.contains("processing/translations/paper-a-zh.pdf"))
    }

    @Test func actionLabelsIncludeTranslateAndDiscuss() {
        #expect(SupersetAction.allCases.map(\.label) == ["重新分析", "格式整理", "制作译本", "对话讨论"])
    }

    @Test func promptBuilderUsesDistinctActionIntentAndStablePaths() {
        let reanalyze = SupersetPromptBuilder.prompt(
            action: .reanalyze,
            targetRelativePath: "vault/papers/a.md",
            targetAbsolutePath: "/tmp/marple-workspace/vault/papers/a.md",
            contextPackagePath: "/tmp/context.md"
        )
        let format = SupersetPromptBuilder.prompt(
            action: .format,
            targetRelativePath: "vault/papers/a.md",
            targetAbsolutePath: "/tmp/marple-workspace/vault/papers/a.md",
            contextPackagePath: "/tmp/context.md"
        )
        let translate = SupersetPromptBuilder.prompt(
            action: .translate,
            targetRelativePath: "vault/papers/a.md",
            targetAbsolutePath: "/tmp/marple-workspace/vault/papers/a.md",
            contextPackagePath: "/tmp/context.md"
        )
        let discuss = SupersetPromptBuilder.prompt(
            action: .discuss,
            targetRelativePath: "vault/papers/a.md",
            targetAbsolutePath: "/tmp/marple-workspace/vault/papers/a.md",
            contextPackagePath: "/tmp/context.md"
        )

        #expect(reanalyze.contains("重新分析"))
        #expect(reanalyze.contains("analyse-agent"))
        #expect(reanalyze.contains("synthesis-agent"))
        #expect(format.contains("格式整理"))
        #expect(format.contains("quasi:audit-agent"))
        #expect(format.contains("quasi-audit --path vault/papers/a.md"))
        #expect(translate.contains("制作译本"))
        #expect(translate.contains("quasi:translate-agent"))
        #expect(translate.contains("quasi-translate"))
        #expect(discuss.contains("对话讨论"))
        #expect(discuss.contains("客观、中立、批判性"))
        #expect(reanalyze.contains("vault/papers/a.md"))
        #expect(reanalyze.contains("/tmp/marple-workspace/vault/papers/a.md"))
        #expect(format.contains("vault/papers/a.md"))
        #expect(format.contains("/tmp/marple-workspace/vault/papers/a.md"))
        #expect(translate.contains("/tmp/context.md"))
        #expect(discuss.contains("/tmp/context.md"))
        #expect(Set([reanalyze, format, translate, discuss]).count == 4)
    }

    @Test func promptBuilderRendersCustomTemplateAndKeepsSafetyBoundary() {
        let prompt = SupersetPromptBuilder.prompt(
            action: .format,
            targetRelativePath: "vault/papers/a.md",
            targetAbsolutePath: "/tmp/marple-workspace/vault/papers/a.md",
            contextPackagePath: "/tmp/context.md",
            promptIntent: "请执行 {{action}}：{{target_relative_path}} / {{target_absolute_path}} / {{context_package_path}}"
        )

        #expect(prompt.contains("请执行 格式整理：vault/papers/a.md / /tmp/marple-workspace/vault/papers/a.md / /tmp/context.md"))
        #expect(!prompt.contains("{{action}}"))
        #expect(!prompt.contains("{{target_relative_path}}"))
        #expect(prompt.contains("请先阅读上下文包。只编辑目标文件，不要编辑上下文包或其他文件。"))
        #expect(prompt.contains("quasi-audit 是唯一入口"))
        #expect(!prompt.contains("不要改变核心观点"))
    }

    @Test func reanalysisPromptAllowsSameBookCompletionWhenNeeded() {
        let prompt = SupersetPromptBuilder.prompt(
            action: .reanalyze,
            targetRelativePath: "vault/books/book-a/00-overview.md",
            targetAbsolutePath: "/tmp/marple-workspace/vault/books/book-a/00-overview.md",
            contextPackagePath: "/tmp/context.md"
        )

        #expect(prompt.contains("默认优先编辑目标文件"))
        #expect(prompt.contains("同一本书目录内缺失的章节分析文件"))
        #expect(prompt.contains("不要因为默认目标文件边界而跳过必要的章节补全"))
        #expect(!prompt.contains("只编辑目标文件，不要编辑上下文包或其他文件。"))
    }

    @Test func discussionPromptUsesNoEditBoundary() {
        let prompt = SupersetPromptBuilder.prompt(
            action: .discuss,
            targetRelativePath: "vault/papers/a.md",
            targetAbsolutePath: "/tmp/marple-workspace/vault/papers/a.md",
            contextPackagePath: "/tmp/context.md",
            promptIntent: "围绕 {{target_relative_path}} 聊聊"
        )

        #expect(prompt.contains("围绕 vault/papers/a.md 聊聊"))
        #expect(prompt.contains("本动作只用于对话讨论，不要编辑、创建或删除任何文件。"))
        #expect(!prompt.contains("只编辑目标文件"))
    }

    @Test func dispatchConfigChoosesCustomPromptByActionAndFallsBackForBlankPrompt() {
        let config = SupersetDispatchConfig(
            workspaceID: "ws_123",
            reanalyzePrompt: "重做 {{target_relative_path}}",
            formatPrompt: "  \n\t  "
        )

        #expect(config.promptIntent(for: .reanalyze) == "重做 {{target_relative_path}}")
        #expect(config.promptIntent(for: .format) == SupersetAction.format.defaultPromptIntent)
        #expect(config.promptIntent(for: .format).contains("audit-agent"))
    }

    @Test func defaultPromptsWrapSingleQuasiCapabilities() {
        #expect(SupersetAction.format.defaultPromptIntent.contains("quasi:audit-agent"))
        #expect(SupersetAction.format.defaultPromptIntent.contains("quasi-audit --path {{target_relative_path}}"))
        #expect(SupersetAction.format.defaultPromptIntent.contains("quasi-audit 是唯一入口"))
        #expect(SupersetAction.format.defaultPromptIntent.contains("保留原事实和原措辞"))
        #expect(!SupersetAction.format.defaultPromptIntent.contains("analyse-agent"))
        #expect(SupersetAction.reanalyze.defaultPromptIntent.contains("analyse-agent"))
        #expect(SupersetAction.reanalyze.defaultPromptIntent.contains("synthesis-agent"))
        #expect(SupersetAction.reanalyze.defaultPromptIntent.contains("quasi:process-book"))
        #expect(!SupersetAction.reanalyze.defaultPromptIntent.contains("audit-agent"))
        #expect(SupersetAction.translate.defaultPromptIntent.contains("quasi:translate-agent"))
        #expect(SupersetAction.translate.defaultPromptIntent.contains("processing/translations/{slug}-zh.pdf"))
        #expect(SupersetAction.discuss.defaultPromptIntent.contains("不要编辑任何文件"))
    }

    @Test func contextPackageWritesToTemporaryMarkdownFile() throws {
        let context = try SupersetDispatchContext(
            workspaceRoot: "/tmp/marple-workspace",
            targetPath: "vault/papers/a.md",
            entry: entry,
            documentText: "Body",
            related: SupersetRelatedContext()
        )

        let url = try SupersetContextPackageBuilder.write(action: .reanalyze, context: context)
        let text = try String(contentsOf: url, encoding: .utf8)

        #expect(url.lastPathComponent == "context.md")
        #expect(text.contains("vault/papers/a.md"))
        #expect(text.contains("Body"))
    }

    @Test func dispatchContextRejectsParentTraversalTargetPath() {
        #expect(throws: SupersetContextError.targetEscapesWorkspace) {
            try SupersetDispatchContext(
                workspaceRoot: "/tmp/marple-workspace",
                targetPath: "../outside.md",
                entry: entry,
                documentText: "Body",
                related: SupersetRelatedContext()
            )
        }
    }

    @Test func dispatchContextRejectsAbsoluteTargetPath() {
        #expect(throws: SupersetContextError.absoluteTargetPath) {
            try SupersetDispatchContext(
                workspaceRoot: "/tmp/marple-workspace",
                targetPath: "/tmp/outside.md",
                entry: entry,
                documentText: "Body",
                related: SupersetRelatedContext()
            )
        }
    }

    @Test func relatedEntryUsesNilSummaryForEmptyPreview() {
        let entryWithoutPreview = Entry(
            path: "vault/papers/empty.md",
            type: .paper,
            title: "Empty Preview",
            author: [],
            year: nil,
            ratingScore: 0,
            themes: [],
            preview: "  \n\t  ",
            hasPDF: false
        )

        let related = SupersetRelatedEntry(entry: entryWithoutPreview, reason: "test")

        #expect(related.summary == nil)
    }

    @Test func templateInvocationRunsTemplateThroughLoginShell() {
        let invocation = SupersetRunner.templateInvocation(
            template: "echo hi",
            environment: ["MARPLE_AGENT": "claude"]
        )

        #expect(invocation.executablePath == "/bin/zsh")
        #expect(invocation.arguments == ["-lc", "echo hi"])
        #expect(invocation.environment["MARPLE_AGENT"] == "claude")
    }

    @Test func dispatchEnvironmentExportsMarpleVariablesAndAugmentedPATH() {
        let environment = SupersetRunner.dispatchEnvironment(
            agent: "claude",
            workspaceID: "ws_123",
            cliPath: "/opt/bin/superset",
            vaultRoot: "/tmp/vault",
            title: "对话讨论 · a.md",
            promptFilePath: "/tmp/pkg/prompt.md",
            contextFilePath: "/tmp/pkg/context.md",
            runScriptPath: "/tmp/pkg/run.command",
            basePATH: "/usr/bin:/bin"
        )

        #expect(environment["MARPLE_AGENT"] == "claude")
        #expect(environment["MARPLE_WORKSPACE"] == "ws_123")
        #expect(environment["MARPLE_SUPERSET_CLI"] == "/opt/bin/superset")
        #expect(environment["MARPLE_VAULT_ROOT"] == "/tmp/vault")
        #expect(environment["MARPLE_TITLE"] == "对话讨论 · a.md")
        #expect(environment["MARPLE_PROMPT_FILE"] == "/tmp/pkg/prompt.md")
        #expect(environment["MARPLE_CONTEXT_FILE"] == "/tmp/pkg/context.md")
        #expect(environment["MARPLE_RUN_SCRIPT"] == "/tmp/pkg/run.command")
        let path = environment["PATH"] ?? ""
        // Absolute CLI path contributes its directory; known install dirs and
        // the inherited PATH follow.
        #expect(path.hasPrefix("/opt/bin:"))
        #expect(path.contains("/.superset/bin"))
        #expect(path.contains("/Applications/Orca.app/Contents/Resources/bin"))
        #expect(path.hasSuffix(":/usr/bin:/bin"))
    }

    @Test func runScriptChangesToVaultAndHandsPromptToAgent() {
        let script = SupersetRunner.runScript(
            agent: "claude",
            vaultRoot: "/tmp/my vault",
            promptFilePath: "/tmp/pkg/prompt.md"
        )

        #expect(script.hasPrefix("#!/bin/zsh\nset -e\n"))
        #expect(script.contains("cd '/tmp/my vault'"))
        #expect(script.contains("marple_prompt=\"$(cat '/tmp/pkg/prompt.md')\""))
        #expect(script.contains("exec claude \"$marple_prompt\""))
    }

    // Integration: really run the generated launcher through zsh with awkward
    // paths and prompt content — the check that fails if quoting breaks.
    @Test func runScriptExecutionSurvivesQuotesAndSpaces() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("marple-runscript-\(UUID().uuidString)", isDirectory: true)
        let vault = base.appendingPathComponent("it's a vault", isDirectory: true)
        try fileManager.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: base) }
        let promptURL = base.appendingPathComponent("my prompt's file.md")
        let promptContent = "line1 \"quoted\" $HOME 'single'\nline2"
        try promptContent.write(to: promptURL, atomically: true, encoding: .utf8)
        let scriptURL = base.appendingPathComponent("run.command")
        try SupersetRunner.runScript(
            agent: "/usr/bin/printf %s",
            vaultRoot: vault.path,
            promptFilePath: promptURL.path
        ).write(to: scriptURL, atomically: true, encoding: .utf8)

        let result = try await SupersetRunner.defaultExecute(
            SupersetInvocation(executablePath: "/bin/zsh", arguments: [scriptURL.path])
        )

        #expect(result.terminationStatus == 0)
        #expect(result.stdout == promptContent)
    }

    @Test func runScriptExecutionAbortsWhenPromptFileMissing() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("marple-runscript-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: base) }
        let scriptURL = base.appendingPathComponent("run.command")
        try SupersetRunner.runScript(
            agent: "/usr/bin/printf agent-ran",
            vaultRoot: base.path,
            promptFilePath: base.appendingPathComponent("missing.md").path
        ).write(to: scriptURL, atomically: true, encoding: .utf8)

        let result = try await SupersetRunner.defaultExecute(
            SupersetInvocation(executablePath: "/bin/zsh", arguments: [scriptURL.path])
        )

        #expect(result.terminationStatus != 0)
        #expect(!result.stdout.contains("agent-ran"))
    }

    // Integration: template expansion happens inside zsh from MARPLE_* env
    // vars — verify awkward values round-trip without shell mangling.
    @Test func templateExecutionExpandsEnvironmentVerbatim() async throws {
        let title = #"weird "title" with $dollar 'quote'"#
        let invocation = SupersetRunner.templateInvocation(
            template: #"printf '%s' "$MARPLE_TITLE""#,
            environment: ["MARPLE_TITLE": title]
        )

        let result = try await SupersetRunner.defaultExecute(invocation)

        #expect(result.terminationStatus == 0)
        // -l sources the user's zprofile, which may print noise; contains is enough.
        #expect(result.stdout.contains(title))
    }

    @Test func resolveTemplateFallsBackByStoredTarget() {
        // Legacy install: nothing stored ⇒ unchanged Superset flow.
        #expect(AIDispatchTarget.resolveTemplate(targetRawValue: nil, storedTemplate: nil)
            == AIDispatchTarget.superset.defaultTemplate)
        #expect(AIDispatchTarget.resolveTemplate(targetRawValue: "orca", storedTemplate: " \n ")
            == AIDispatchTarget.orca.defaultTemplate)
        #expect(AIDispatchTarget.resolveTemplate(targetRawValue: "custom", storedTemplate: "echo hi")
            == "echo hi")
        // Custom with nothing stored resolves empty ⇒ dispatch reports the
        // missing-template error instead of silently running a preset.
        #expect(AIDispatchTarget.resolveTemplate(targetRawValue: "custom", storedTemplate: nil).isEmpty)
        #expect(AIDispatchTarget.resolveTemplate(targetRawValue: "garbage", storedTemplate: nil)
            == AIDispatchTarget.superset.defaultTemplate)
    }

    @Test func shellQuoteEscapesSingleQuotes() {
        #expect(SupersetRunner.shellQuote("it's") == "'it'\\''s'")
    }

    @Test func defaultTemplatesCoverKnownTargets() {
        #expect(AIDispatchTarget.superset.defaultTemplate.hasPrefix("\"$MARPLE_SUPERSET_CLI\""))
        #expect(AIDispatchTarget.superset.defaultTemplate.contains("agents create"))
        #expect(AIDispatchTarget.superset.defaultTemplate.contains("$MARPLE_WORKSPACE"))
        #expect(AIDispatchTarget.superset.defaultTemplate.contains("--attachment \"$MARPLE_CONTEXT_FILE\""))
        #expect(AIDispatchTarget.orca.defaultTemplate.contains("terminal create"))
        #expect(AIDispatchTarget.orca.defaultTemplate.contains("path:$MARPLE_VAULT_ROOT"))
        #expect(AIDispatchTarget.orca.defaultTemplate.contains("$MARPLE_RUN_SCRIPT"))
        #expect(AIDispatchTarget.otty.defaultTemplate == #"open -a Otty "$MARPLE_RUN_SCRIPT""#)
        #expect(AIDispatchTarget.terminal.defaultTemplate == #"open -a Terminal "$MARPLE_RUN_SCRIPT""#)
        #expect(AIDispatchTarget.custom.defaultTemplate.isEmpty)
    }

    @Test func resolveCLIPathPrefersKnownInstallLocationForBareName() {
        let resolved = SupersetRunner.resolveCLIPath(
            "superset",
            searchDirectories: ["/opt/missing", "/Users/me/.superset/bin"],
            isExecutable: { $0 == "/Users/me/.superset/bin/superset" }
        )

        #expect(resolved == "/Users/me/.superset/bin/superset")
    }

    @Test func resolveCLIPathResolvesEmptyPathToSupersetBinary() {
        let resolved = SupersetRunner.resolveCLIPath(
            "",
            searchDirectories: ["/Users/me/.superset/bin"],
            isExecutable: { $0 == "/Users/me/.superset/bin/superset" }
        )

        #expect(resolved == "/Users/me/.superset/bin/superset")
    }

    @Test func resolveCLIPathRespectsExplicitPathWithSlash() {
        let resolved = SupersetRunner.resolveCLIPath(
            "/custom/superset",
            searchDirectories: ["/Users/me/.superset/bin"],
            isExecutable: { _ in true }
        )

        #expect(resolved == "/custom/superset")
    }

    @Test func resolveCLIPathFallsBackToInputWhenNotFound() {
        let resolved = SupersetRunner.resolveCLIPath(
            "superset",
            searchDirectories: ["/opt/missing", "/also/missing"],
            isExecutable: { _ in false }
        )

        #expect(resolved == "superset")
    }

    @Test func workspaceListInvocationUsesJSONLocalWorkspacesCommand() {
        let invocation = SupersetRunner.workspaceListInvocation(cliPath: "superset")

        #expect(invocation.executablePath == "/usr/bin/env")
        #expect(invocation.arguments == ["superset", "workspaces", "list", "--json", "--local"])
    }

    @Test func workspaceIDsParserTrimsAndDeduplicates() {
        let ids = SupersetRunner.workspaceIDs(from: "  ws_123  \n\nws_456\nws_123\n")

        #expect(ids == ["ws_123", "ws_456"])
    }

    @Test func workspaceJSONParserBuildsReadableLabelsAndDeduplicates() throws {
        let json = """
        [
          {"id":"ws_123","name":"基于 Superset CLI 的自动化功能","branch":"qua-45-superset-cli","projectName":"marple","hostName":"RamuG","type":"worktree"},
          {"id":"ws_456","name":"main","branch":"main","projectName":"quasi","hostName":"RamuG","type":"main"},
          {"id":"ws_123","name":"duplicate","branch":"main","projectName":"marple","hostName":"RamuG","type":"main"}
        ]
        """

        let workspaces = try SupersetRunner.workspaces(from: json)

        #expect(workspaces.map(\.id) == ["ws_123", "ws_456"])
        #expect(workspaces[0].displayName == "marple / 基于 Superset CLI 的自动化功能 (qua-45-superset-cli) · RamuG · worktree")
        #expect(workspaces[1].displayName == "quasi / main · RamuG · main")
    }

    @Test func runnerListsWorkspaceIDs() async throws {
        let runner = SupersetRunner { invocation in
            // Resolution may turn a bare `superset` into an absolute executable
            // (dropping the leading argv) when the CLI is installed locally;
            // assert the workspaces command regardless of how it's targeted.
            #expect(invocation.executablePath.hasSuffix("superset") || invocation.arguments.first == "superset")
            #expect(Array(invocation.arguments.suffix(4)) == ["workspaces", "list", "--json", "--local"])
            return SupersetProcessResult(terminationStatus: 0, stdout: """
            [
              {"id":"ws_123","name":"Current","branch":"main","projectName":"marple","hostName":"RamuG","type":"worktree"},
              {"id":"ws_456","name":"main","branch":"main","projectName":"quasi","hostName":"RamuG","type":"main"}
            ]
            """, stderr: "")
        }

        let ids = try await runner.listWorkspaceIDs(cliPath: "superset")

        #expect(ids == ["ws_123", "ws_456"])
    }

    @Test func runnerReportsWorkspaceListAuthFailure() async {
        let runner = SupersetRunner { _ in
            SupersetProcessResult(terminationStatus: 1, stdout: "", stderr: "Error: Not logged in")
        }

        await #expect(throws: SupersetWorkspaceListError.notAuthenticated) {
            try await runner.listWorkspaceIDs(cliPath: "superset")
        }
    }

    @Test func runnerTreatsInvalidAPIKeyAsAuthFailure() async {
        let runner = SupersetRunner { _ in
            SupersetProcessResult(terminationStatus: 1, stdout: "", stderr: "Error: Invalid API key.")
        }

        await #expect(throws: SupersetWorkspaceListError.notAuthenticated) {
            try await runner.listWorkspaceIDs(cliPath: "superset")
        }
    }

    @Test func runnerReportsWorkspaceListLaunchFailure() async {
        let log = LogBox()
        let runner = SupersetRunner(
            execute: { _ in throw SupersetDispatchError.launchFailed("No such file") },
            log: { log.append($0) }
        )

        await #expect(throws: SupersetWorkspaceListError.launchFailed("No such file")) {
            try await runner.listWorkspaceIDs(cliPath: "superset")
        }

        #expect(log.entries.count == 1)
        #expect(log.entries.first?.contains("No such file") == true)
    }

    @Test func runnerRejectsMissingWorkspaceID() async throws {
        let context = try SupersetDispatchContext(
            workspaceRoot: "/tmp/marple-workspace",
            targetPath: "vault/papers/a.md",
            entry: entry,
            documentText: "Body",
            related: SupersetRelatedContext()
        )
        let runner = SupersetRunner { _ in
            Issue.record("runner should not execute without workspace ID")
            return SupersetProcessResult(terminationStatus: 0, stdout: "", stderr: "")
        }

        await #expect(throws: SupersetDispatchError.missingWorkspaceID) {
            try await runner.dispatch(
                action: .reanalyze,
                config: SupersetDispatchConfig(workspaceID: "   "),
                context: context
            )
        }
    }

    @Test func runnerConvertsNonZeroExitToDispatchError() async throws {
        let context = try SupersetDispatchContext(
            workspaceRoot: "/tmp/marple-workspace",
            targetPath: "vault/papers/a.md",
            entry: entry,
            documentText: "Body",
            related: SupersetRelatedContext()
        )
        let log = LogBox()
        let runner = SupersetRunner(
            execute: { invocation in
                #expect(invocation.environment["MARPLE_CONTEXT_FILE"] != nil)
                return SupersetProcessResult(terminationStatus: 2, stdout: "", stderr: "bad workspace")
            },
            log: { log.append($0) }
        )

        await #expect(throws: SupersetDispatchError.failed(status: 2, stderr: "bad workspace")) {
            try await runner.dispatch(
                action: .format,
                config: SupersetDispatchConfig(workspaceID: "ws_123"),
                context: context
            )
        }

        // QUA-192: exit code and stderr land in the persistent log behind the
        // "请查看日志" hint instead of a print() the GUI never shows.
        let entry = try #require(log.entries.first)
        #expect(entry.contains("退出码 2"))
        #expect(entry.contains("bad workspace"))
        #expect(entry.contains("vault/papers/a.md"))
    }

    @Test func runnerLogsStdoutWhenStderrEmptyOnFailure() async throws {
        let context = try SupersetDispatchContext(
            workspaceRoot: "/tmp/marple-workspace",
            targetPath: "vault/papers/a.md",
            entry: entry,
            documentText: "Body",
            related: SupersetRelatedContext()
        )
        let log = LogBox()
        let runner = SupersetRunner(
            execute: { _ in SupersetProcessResult(terminationStatus: 1, stdout: "fatal: boom", stderr: "") },
            log: { log.append($0) }
        )

        await #expect(throws: SupersetDispatchError.failed(status: 1, stderr: "")) {
            try await runner.dispatch(
                action: .reanalyze,
                config: SupersetDispatchConfig(workspaceID: "ws_123"),
                context: context
            )
        }

        #expect(log.entries.first?.contains("fatal: boom") == true)
    }

    @Test func runnerDoesNotLogAuthFailureAsError() async {
        let log = LogBox()
        let runner = SupersetRunner(
            execute: { _ in SupersetProcessResult(terminationStatus: 1, stdout: "", stderr: "Error: Not logged in") },
            log: { log.append($0) }
        )

        await #expect(throws: SupersetWorkspaceListError.notAuthenticated) {
            try await runner.listWorkspaceIDs(cliPath: "superset")
        }

        #expect(log.entries.isEmpty)
    }

    @Test func supersetLogFormatsTimestampedLineWithTrailingNewline() {
        let line = SupersetLog.line("boom", timestamp: Date(timeIntervalSince1970: 0))

        #expect(line == "[1970-01-01T00:00:00Z] boom\n")
    }

    @Test func supersetLogAppendsToFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("marple-superset-log-test-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("superset.log")
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = SupersetLog(fileURL: fileURL)
        log.append("first", timestamp: Date(timeIntervalSince1970: 0))
        log.append("second", timestamp: Date(timeIntervalSince1970: 1))

        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(contents == "[1970-01-01T00:00:00Z] first\n[1970-01-01T00:00:01Z] second\n")
    }

    @Test func runnerExecutesSuccessfulDispatch() async throws {
        let context = try SupersetDispatchContext(
            workspaceRoot: "/tmp/marple-workspace",
            targetPath: "vault/papers/a.md",
            entry: entry,
            documentText: "Body",
            related: SupersetRelatedContext()
        )
        final class InvocationBox: @unchecked Sendable {
            var invocation: SupersetInvocation?
        }
        let box = InvocationBox()
        let runner = SupersetRunner { invocation in
            box.invocation = invocation
            return SupersetProcessResult(terminationStatus: 0, stdout: "run_123", stderr: "")
        }

        try await runner.dispatch(
            action: .reanalyze,
            config: SupersetDispatchConfig(workspaceID: "ws_123", agent: "claude", cliPath: "superset"),
            context: context
        )

        // The default (Superset) template runs through the login shell with the
        // workspace exported in the environment.
        let invocation = try #require(box.invocation)
        #expect(invocation.executablePath == "/bin/zsh")
        #expect(invocation.arguments.first == "-lc")
        #expect(invocation.arguments.last?.contains("agents create") == true)
        #expect(invocation.environment["MARPLE_WORKSPACE"] == "ws_123")
        #expect(invocation.environment["MARPLE_AGENT"] == "claude")
    }

    @Test func runnerPassesCustomPromptIntentToInvocation() async throws {
        let context = try SupersetDispatchContext(
            workspaceRoot: "/tmp/marple-workspace",
            targetPath: "vault/papers/a.md",
            entry: entry,
            documentText: "Body",
            related: SupersetRelatedContext()
        )
        final class PromptBox: @unchecked Sendable {
            var prompt: String?
        }
        let box = PromptBox()
        let runner = SupersetRunner { invocation in
            let promptPath = try #require(invocation.environment["MARPLE_PROMPT_FILE"])
            box.prompt = try String(contentsOfFile: promptPath, encoding: .utf8)
            return SupersetProcessResult(terminationStatus: 0, stdout: "run_123", stderr: "")
        }

        try await runner.dispatch(
            action: .format,
            config: SupersetDispatchConfig(
                workspaceID: "ws_123",
                agent: "claude",
                cliPath: "superset",
                formatPrompt: "格式化 {{target_relative_path}}"
            ),
            context: context
        )

        let prompt = try #require(box.prompt)
        #expect(prompt.contains("格式化 vault/papers/a.md"))
        #expect(!prompt.contains("不要改变核心观点"))
        #expect(prompt.contains("请先阅读上下文包。只编辑目标文件，不要编辑上下文包或其他文件。"))
    }

    // The package files must outlive dispatch: terminal targets (`open -a …`)
    // return before the agent has read prompt.md / context.md.
    @Test func runnerKeepsPackageFilesAliveAfterDispatch() async throws {
        let context = try SupersetDispatchContext(
            workspaceRoot: "/tmp/marple-workspace",
            targetPath: "vault/papers/a.md",
            entry: entry,
            documentText: "Body",
            related: SupersetRelatedContext()
        )
        final class EnvBox: @unchecked Sendable {
            var environment: [String: String] = [:]
        }
        let box = EnvBox()
        let runner = SupersetRunner { invocation in
            box.environment = invocation.environment
            return SupersetProcessResult(terminationStatus: 0, stdout: "run_123", stderr: "")
        }

        try await runner.dispatch(
            action: .discuss,
            config: SupersetDispatchConfig(workspaceID: "ws_123", agent: "claude", cliPath: "superset"),
            context: context
        )

        let contextPath = try #require(box.environment["MARPLE_CONTEXT_FILE"])
        let promptPath = try #require(box.environment["MARPLE_PROMPT_FILE"])
        let runScriptPath = try #require(box.environment["MARPLE_RUN_SCRIPT"])
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: contextPath).deletingLastPathComponent()) }
        #expect(FileManager.default.fileExists(atPath: contextPath))
        let prompt = try String(contentsOfFile: promptPath, encoding: .utf8)
        #expect(prompt.contains("对话讨论"))
        let runScript = try String(contentsOfFile: runScriptPath, encoding: .utf8)
        #expect(runScript.contains("exec claude"))
        #expect(FileManager.default.isExecutableFile(atPath: runScriptPath))
    }

    @Test func runnerSkipsWorkspaceRequirementWhenTemplateOmitsIt() async throws {
        let context = try SupersetDispatchContext(
            workspaceRoot: "/tmp/marple-workspace",
            targetPath: "vault/papers/a.md",
            entry: entry,
            documentText: "Body",
            related: SupersetRelatedContext()
        )
        final class InvocationBox: @unchecked Sendable {
            var invocation: SupersetInvocation?
        }
        let box = InvocationBox()
        let runner = SupersetRunner { invocation in
            box.invocation = invocation
            return SupersetProcessResult(terminationStatus: 0, stdout: "", stderr: "")
        }

        try await runner.dispatch(
            action: .discuss,
            config: SupersetDispatchConfig(
                workspaceID: "",
                commandTemplate: AIDispatchTarget.terminal.defaultTemplate
            ),
            context: context
        )

        let invocation = try #require(box.invocation)
        #expect(invocation.arguments.last == AIDispatchTarget.terminal.defaultTemplate)
        #expect(invocation.environment["MARPLE_WORKSPACE"] == "")
        if let contextPath = invocation.environment["MARPLE_CONTEXT_FILE"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: contextPath).deletingLastPathComponent())
        }
    }

    @Test func runnerRejectsEmptyCommandTemplate() async throws {
        let context = try SupersetDispatchContext(
            workspaceRoot: "/tmp/marple-workspace",
            targetPath: "vault/papers/a.md",
            entry: entry,
            documentText: "Body",
            related: SupersetRelatedContext()
        )
        let runner = SupersetRunner { _ in
            Issue.record("runner should not execute without a template")
            return SupersetProcessResult(terminationStatus: 0, stdout: "", stderr: "")
        }

        await #expect(throws: SupersetDispatchError.missingCommandTemplate) {
            try await runner.dispatch(
                action: .discuss,
                config: SupersetDispatchConfig(workspaceID: "ws_123", commandTemplate: "  \n "),
                context: context
            )
        }
    }
}
