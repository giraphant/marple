import Foundation
import Testing
@testable import MarpleKit

@Suite struct SupersetAutomationTests {
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
        #expect(markdown.contains("Only edit the target file above. Do not edit this context package."))
        #expect(markdown.contains("- Type: paper"))
        #expect(markdown.contains("- Title: Paper A"))
        #expect(markdown.contains("- Author: Jane Doe"))
        #expect(markdown.contains("- Themes: AI, workflow"))
        #expect(markdown.contains("# Old analysis"))
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

        #expect(reanalyze.contains("重新分析"))
        #expect(reanalyze.contains("analyse-agent"))
        #expect(reanalyze.contains("synthesis-agent"))
        #expect(format.contains("格式整理"))
        #expect(format.contains("audit-agent"))
        #expect(format.contains("quasi-audit"))
        #expect(reanalyze.contains("vault/papers/a.md"))
        #expect(reanalyze.contains("/tmp/marple-workspace/vault/papers/a.md"))
        #expect(format.contains("vault/papers/a.md"))
        #expect(format.contains("/tmp/marple-workspace/vault/papers/a.md"))
        #expect(reanalyze.contains("/tmp/context.md"))
        #expect(format.contains("/tmp/context.md"))
        #expect(reanalyze != format)
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
        #expect(!prompt.contains("不要改变核心观点"))
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
        #expect(SupersetAction.format.defaultPromptIntent.contains("audit-agent"))
        #expect(SupersetAction.format.defaultPromptIntent.contains("quasi-audit"))
        #expect(!SupersetAction.format.defaultPromptIntent.contains("analyse-agent"))
        #expect(SupersetAction.reanalyze.defaultPromptIntent.contains("analyse-agent"))
        #expect(SupersetAction.reanalyze.defaultPromptIntent.contains("synthesis-agent"))
        #expect(!SupersetAction.reanalyze.defaultPromptIntent.contains("audit-agent"))
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

    @Test func invocationUsesEnvWhenCLIPathIsCommandName() throws {
        let invocation = SupersetRunner.invocation(
            config: SupersetDispatchConfig(workspaceID: "ws_123", agent: "claude", cliPath: "superset"),
            prompt: "Prompt text",
            contextPackagePath: "/tmp/context.md"
        )

        #expect(invocation.executablePath == "/usr/bin/env")
        #expect(invocation.arguments == [
            "superset", "agents", "run",
            "--workspace", "ws_123",
            "--agent", "claude",
            "--prompt", "Prompt text",
            "--attachment", "/tmp/context.md"
        ])
    }

    @Test func invocationUsesAbsoluteCLIPathDirectly() throws {
        let invocation = SupersetRunner.invocation(
            config: SupersetDispatchConfig(workspaceID: "ws_123", agent: "superset", cliPath: "/opt/bin/superset"),
            prompt: "Prompt text",
            contextPackagePath: "/tmp/context.md"
        )

        #expect(invocation.executablePath == "/opt/bin/superset")
        #expect(invocation.arguments.first == "agents")
        #expect(invocation.arguments.contains("superset"))
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
            #expect(invocation.arguments == ["superset", "workspaces", "list", "--json", "--local"])
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

    @Test func runnerReportsWorkspaceListLaunchFailure() async {
        let runner = SupersetRunner { _ in
            throw SupersetDispatchError.launchFailed("No such file")
        }

        await #expect(throws: SupersetWorkspaceListError.launchFailed("No such file")) {
            try await runner.listWorkspaceIDs(cliPath: "superset")
        }
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
        let runner = SupersetRunner { invocation in
            #expect(invocation.arguments.contains("--attachment"))
            return SupersetProcessResult(terminationStatus: 2, stdout: "", stderr: "bad workspace")
        }

        await #expect(throws: SupersetDispatchError.failed(status: 2, stderr: "bad workspace")) {
            try await runner.dispatch(
                action: .format,
                config: SupersetDispatchConfig(workspaceID: "ws_123"),
                context: context
            )
        }
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

        #expect(box.invocation?.executablePath == "/usr/bin/env")
        #expect(box.invocation?.arguments.contains("--workspace") == true)
        #expect(box.invocation?.arguments.contains("ws_123") == true)
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
            let promptIndex = try #require(invocation.arguments.firstIndex(of: "--prompt"))
            let promptValueIndex = invocation.arguments.index(after: promptIndex)
            box.prompt = invocation.arguments[promptValueIndex]
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

    @Test func runnerRemovesContextPackageAfterDispatch() async throws {
        let context = try SupersetDispatchContext(
            workspaceRoot: "/tmp/marple-workspace",
            targetPath: "vault/papers/a.md",
            entry: entry,
            documentText: "Body",
            related: SupersetRelatedContext()
        )
        final class AttachmentBox: @unchecked Sendable {
            var url: URL?
        }
        let box = AttachmentBox()
        let runner = SupersetRunner { invocation in
            let attachmentIndex = try #require(invocation.arguments.firstIndex(of: "--attachment"))
            let attachmentPathIndex = invocation.arguments.index(after: attachmentIndex)
            let attachmentURL = URL(fileURLWithPath: invocation.arguments[attachmentPathIndex])
            box.url = attachmentURL
            #expect(FileManager.default.fileExists(atPath: attachmentURL.path))
            return SupersetProcessResult(terminationStatus: 0, stdout: "run_123", stderr: "")
        }

        try await runner.dispatch(
            action: .reanalyze,
            config: SupersetDispatchConfig(workspaceID: "ws_123", agent: "claude", cliPath: "superset"),
            context: context
        )

        let attachmentURL = try #require(box.url)
        #expect(!FileManager.default.fileExists(atPath: attachmentURL.path))
        #expect(!FileManager.default.fileExists(atPath: attachmentURL.deletingLastPathComponent().path))
    }
}
