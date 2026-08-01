import SwiftUI
import AppKit
import MarpleKit

/// The macOS preferences window (⌘,). Tabs are grouped by what the user is
/// doing: display (外观/阅读) → vault organization (类型/空间) → data
/// maintenance (索引/备份) → integrations (AI 接入).
struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettings()
                .tabItem { Label("外观", systemImage: "paintbrush") }
            ReadingSettings()
                // Not "textformat": that symbol has a zh-Hans variant that renders
                // as the characters 格式 instead of a graphic icon.
                .tabItem { Label("阅读", systemImage: "book") }
            SchemaSettings()
                .tabItem { Label("类型", systemImage: "tablecells") }
            SpacesSettings()
                .tabItem { Label("空间", systemImage: "square.stack") }
            IndexSettings()
                .tabItem { Label("索引", systemImage: "externaldrive") }
            AIBridgeSettings()
                .tabItem { Label("智能", systemImage: "sparkles") }
            BackupSettings()
                .tabItem { Label("备份", systemImage: "clock.arrow.circlepath") }
        }
        .frame(width: 620, height: 560)
    }
}

// MARK: - 索引

private struct IndexSettings: View {
    @State private var confirmingRebuild = false
    @State private var isRebuilding = false
    @State private var result: ResultMessage?
    @State private var semanticIndexController: SemanticIndexRefreshController?

    var body: some View {
        Form {
            Section("普通索引") {
                if let model = ActiveModel.current {
                    LabeledContent("条目") {
                        Text("\(model.entries.count)")
                    }
                    LabeledContent("状态") {
                        Text(model.isRebuildingGeneralIndex ? "正在重建" : "就绪")
                            .foregroundStyle(.secondary)
                    }

                    if let failure = model.lastIndexFailure {
                        Text(failure)
                            .foregroundStyle(Color.red)
                            .textSelection(.enabled)
                    } else {
                        Text("当前没有已知的索引障碍。重复的 themes 条目会自动去重。")
                            .foregroundStyle(.secondary)
                    }

                    Button("清除并重建普通索引…") {
                        confirmingRebuild = true
                    }
                    .disabled(isRebuilding || model.isRebuildingGeneralIndex)

                    Text("从 vault 文件重新建立普通索引。新索引完整生成后才会替换当前索引；重建失败时保留当前索引。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("主窗口尚未就绪。")
                        .foregroundStyle(.secondary)
                }
            }

            Section("语义索引") {
                if let semanticIndexController {
                    SemanticIndexRefreshSettings(controller: semanticIndexController)
                } else if ActiveModel.current == nil {
                    Text("主窗口尚未就绪。")
                        .foregroundStyle(.secondary)
                } else {
                    Text("本机缺少 MLX Metal runtime，暂不能刷新语义索引。")
                        .foregroundStyle(.secondary)
                    Text("安装包内需要 mlx.metallib；开发运行时可在当前目录提供 default.metallib。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            semanticIndexController = ActiveSemanticIndex.controller
        }
        .onReceive(NotificationCenter.default.publisher(for: ActiveSemanticIndex.didChangeNotification)) { note in
            semanticIndexController = note.object as? SemanticIndexRefreshController
        }
        .confirmationDialog(
            "清除并重建普通索引？",
            isPresented: $confirmingRebuild,
            titleVisibility: .visible
        ) {
            Button("清除并重建", role: .destructive) { rebuild() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("Marple 会从 vault 文件重新建立索引。只有新索引完整生成后才会替换当前索引。")
        }
        .alert(item: $result) { result in
            Alert(
                title: Text(result.title),
                message: Text(result.detail),
                dismissButton: .default(Text("好"))
            )
        }
    }

    private func rebuild() {
        guard let model = ActiveModel.current else { return }
        isRebuilding = true
        Task { @MainActor in
            result = switch await model.rebuildGeneralIndex() {
            case .success(let count):
                ResultMessage(title: String(localized: "普通索引已重建"), detail: String(localized: "已索引 \(count) 个条目。"))
            case .failure(let detail):
                ResultMessage(title: String(localized: "普通索引重建失败"), detail: detail)
            case .alreadyRunning:
                ResultMessage(title: String(localized: "普通索引正在重建"), detail: String(localized: "请等待当前重建完成。"))
            case .unavailable:
                ResultMessage(title: String(localized: "无法重建普通索引"), detail: String(localized: "主窗口的索引器尚未就绪。"))
            }
            isRebuilding = false
        }
    }

    private struct ResultMessage: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
    }
}

// MARK: - Spaces

/// Where封存的 Spaces are managed (QUA-216). Archived Spaces are hidden from the
/// bottom switcher; here they can be restored or permanently deleted. Reaches the
/// live model via `ActiveModel.current`, same as the other model-backed panes.
private struct SpacesSettings: View {
    var body: some View {
        Form {
            Section("已封存的空间") {
                if let model = ActiveModel.current {
                    let archived = model.archivedSpaces
                    if archived.isEmpty {
                        Text("暂无已封存的空间。右键底部切换栏的空间可选择「封存归档」。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(archived) { space in
                            HStack {
                                Label(space.name, systemImage: space.iconName ?? "square.dashed")
                                Spacer()
                                Button("恢复") { model.unarchiveSpace(space.id) }
                                Button(role: .destructive) {
                                    model.deleteSpace(space.id)
                                } label: { Text("删除") }
                            }
                        }
                    }
                } else {
                    Text("主窗口尚未就绪。").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 外观

private struct AppearanceSettings: View {
    @AppStorage(SettingsKeys.theme) private var theme = ThemePreference.system
    @AppStorage(SettingsKeys.readingFontFamily) private var family = ReadingFontFamily.sans
    @AppStorage(SettingsKeys.readingFontSize) private var size = ReadingDefaults.fontSize
    @AppStorage(SettingsKeys.readingLineHeight) private var lineHeight = ReadingDefaults.lineHeight
    @AppStorage(SettingsKeys.readingLetterSpacing) private var letterSpacing = ReadingDefaults.letterSpacing

    var body: some View {
        Form {
            Section("主题") {
                Picker("主题", selection: $theme) {
                    ForEach(ThemePreference.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Section("阅读排版") {
                Picker("字体", selection: $family) {
                    ForEach(ReadingFontFamily.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)

                Picker("字号", selection: $size) {
                    ForEach(ReadingDefaults.fontSizeOptions, id: \.self) {
                        Text(String(Int($0))).tag($0)
                    }
                }
                .pickerStyle(.segmented)

                Picker("行距", selection: $lineHeight) {
                    ForEach(ReadingDefaults.lineHeightOptions, id: \.self) {
                        Text(String(format: "%.2f", $0)).tag($0)
                    }
                }
                .pickerStyle(.segmented)

                Picker("字间距", selection: $letterSpacing) {
                    ForEach(ReadingDefaults.letterSpacingOptions, id: \.self) {
                        Text(ReadingDefaults.letterSpacingLabel($0)).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                Text("仅作用于中文字符，英文不受影响。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("侧栏物件") {
                SidebarTypeToggles()
                Text("关掉的类型只从侧栏隐藏；⌘T 搜索、已打开的页面和保存的视图不受影响。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Which type buckets the sidebar shows (QUA-127). The Settings scene has no
/// environment injection, so reach the live model the same way the menu-bar
/// commands do — via `ActiveModel.current`.
private struct SidebarTypeToggles: View {
    var body: some View {
        if let model = ActiveModel.current {
            ForEach(model.typeOrder, id: \.self) { type in
                Toggle(isOn: Binding(
                    get: { !model.hiddenTypes.contains(type) },
                    set: { model.setTypeHidden(type, hidden: !$0) }
                )) {
                    Label(AppPresentation.entryTypeLabel(type), systemImage: type.symbolName)
                }
            }
        } else {
            Text("主窗口尚未就绪。").foregroundStyle(.secondary)
        }
    }
}

// MARK: - 阅读

private struct ReadingSettings: View {
    @AppStorage(SettingsKeys.externalEditor) private var editor = ""
    @AppStorage(SettingsKeys.citationFormat) private var format = CitationFormat.inlineEN
    @AppStorage(SettingsKeys.citationClickAction) private var citationClick = CitationClickAction.copyDefault
    @AppStorage(SettingsKeys.originalClickAction) private var originalClick = OriginalClickAction.openOriginal

    var body: some View {
        Form {
            Section("外部编辑器") {
                EditorPicker(value: $editor)
                Text("用应用名打开（`open -a`）；留空则用系统默认 `.md` 程序。改动立即生效。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("引用与原文按钮") {
                Picker("引用", selection: $citationClick) {
                    ForEach(CitationClickAction.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("原文", selection: $originalClick) {
                    ForEach(OriginalClickAction.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("右键始终弹出完整菜单。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("默认引用格式") {
                Picker("格式", selection: $format) {
                    ForEach(CitationFormat.allCases, id: \.self) { Text(AppPresentation.citationFormatLabel($0)).tag($0) }
                }
                .pickerStyle(.inline)
                Text("示例：\(format.example)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Common macOS editors as quick chips, plus a free-text app name for anything
/// else. The value is what gets passed to `open -a` ('' = OS default).
private struct EditorPicker: View {
    @Binding var value: String

    private static let presets: [(app: String, label: String)] = [
        ("", "系统默认"),
        ("Visual Studio Code", "VS Code"),
        ("Typora", "Typora"),
        ("Obsidian", "Obsidian"),
        ("Ulysses", "Ulysses"),
        ("iA Writer", "iA Writer"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            FlowLayout(spacing: Space.s2, lineSpacing: Space.s2) {
                ForEach(Self.presets, id: \.app) { preset in
                    let active = preset.app == value
                    Button {
                        value = preset.app
                    } label: {
                        Text(preset.app.isEmpty ? String(localized: "系统默认") : preset.label)
                    }
                    .buttonStyle(.plain)
                        .font(Typo.body)
                        .padding(.horizontal, Space.s4).padding(.vertical, Space.s2)
                        .background(active ? Color.accentColor.opacity(0.15) : Color(.quaternaryLabelColor).opacity(0.4),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(active ? Color.accentColor : .primary)
                }
            }
            TextField("自定义应用名（如 Sublime Text、Zed、Cursor）", text: $value)
                .textFieldStyle(.roundedBorder)
        }
    }
}

private struct PromptTemplateEditor: View {
    let title: String
    @Binding var prompt: String
    let defaultPrompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack {
                Text(title)
                Spacer()
                Button("恢复默认") { prompt = "" }
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $prompt)
                    .font(.body)
                    .frame(minHeight: 72)
                    .padding(4)
                    .background(Color(.textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(defaultPrompt)
                        .foregroundStyle(Color(.placeholderTextColor))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

// MARK: - AI 接入

/// QUA-107: opt-in switch for the local CLI socket server. Off by default so
/// nothing runs unless the user explicitly turns it on; toggling here flips
/// the listener live (no relaunch needed).
private struct AIBridgeSettings: View {
    /// GUI-pickable agent CLIs; `custom` falls back to a free-text command.
    private enum AgentChoice: String, CaseIterable {
        case claude, codex, custom
        var label: String {
            switch self {
            case .claude: return "Claude Code (claude)"
            case .codex:  return "Codex (codex)"
            case .custom: return String(localized: "自定义")
            }
        }
    }

    @AppStorage(SettingsKeys.cliServerEnabled) private var enabled = false
    @AppStorage(SettingsKeys.aiDispatchTarget) private var dispatchTargetRaw = AIDispatchTarget.superset.rawValue
    @AppStorage(SettingsKeys.aiDispatchTemplate) private var dispatchTemplate = AIDispatchTarget.superset.defaultTemplate
    @AppStorage(SettingsKeys.aiAgentChoice) private var agentChoiceRaw = ""
    @AppStorage(SettingsKeys.supersetWorkspaceID) private var supersetWorkspaceID = ""
    @AppStorage(SettingsKeys.readerAIAgent) private var readerAIAgent = "claude"
    @AppStorage(SettingsKeys.supersetCLIPath) private var supersetCLIPath = "superset"
    @AppStorage(SettingsKeys.readerAIReanalyzePrompt) private var readerAIReanalyzePrompt = ""
    @AppStorage(SettingsKeys.readerAIFormatPrompt) private var readerAIFormatPrompt = ""
    @AppStorage(SettingsKeys.readerAITranslatePrompt) private var readerAITranslatePrompt = ""
    @AppStorage(SettingsKeys.readerAIDiscussPrompt) private var readerAIDiscussPrompt = ""
    @State private var discoveredWorkspaces: [SupersetWorkspace] = []
    @State private var workspaceLookupMessage: String?
    @State private var workspaceLookupIsError = false
    @State private var isLoadingWorkspaces = false

    var body: some View {
        Form {
            Section("阅读助手") {
                Picker("分发目标", selection: Binding(
                    get: { AIDispatchTarget(rawValue: dispatchTargetRaw) ?? .superset },
                    set: { newTarget in
                        dispatchTargetRaw = newTarget.rawValue
                        // Preset picked ⇒ pre-fill its template. 自定义 keeps the
                        // box text but re-persists it, so the displayed template
                        // is exactly what dispatch will run (the AppStorage
                        // default is otherwise never written to disk).
                        dispatchTemplate = newTarget == .custom ? dispatchTemplate : newTarget.defaultTemplate
                    }
                )) {
                    ForEach(AIDispatchTarget.allCases, id: \.self) { Text(AppPresentation.aiDispatchTargetLabel($0)).tag($0) }
                }

                // The choice is stored separately from the command text so typing
                // a custom command that momentarily equals "claude" doesn't
                // flip the picker and hide the field mid-edit.
                let agentChoice = AgentChoice(rawValue: agentChoiceRaw)
                    ?? AgentChoice(rawValue: readerAIAgent)
                    ?? .custom
                Picker("代理", selection: Binding(
                    get: { agentChoice },
                    set: { choice in
                        agentChoiceRaw = choice.rawValue
                        if choice != .custom {
                            readerAIAgent = choice.rawValue
                        }
                    }
                )) {
                    ForEach(AgentChoice.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if agentChoice == .custom {
                    TextField("代理命令（如 claude --model opus）", text: $readerAIAgent)
                        .textFieldStyle(.roundedBorder)
                }

                if AIDispatchTarget(rawValue: dispatchTargetRaw) ?? .superset == .superset {
                    HStack {
                        TextField("Superset 工作区 ID", text: $supersetWorkspaceID)
                            .textFieldStyle(.roundedBorder)
                        Button(isLoadingWorkspaces ? String(localized: "获取中…") : String(localized: "获取")) {
                            Task { await refreshSupersetWorkspaces() }
                        }
                        .disabled(isLoadingWorkspaces)
                    }
                    if !discoveredWorkspaces.isEmpty {
                        Picker("已发现", selection: $supersetWorkspaceID) {
                            ForEach(discoveredWorkspaces) { workspace in
                                Text(workspace.displayName).tag(workspace.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    if let workspaceLookupMessage {
                        Text(workspaceLookupMessage)
                            .font(.caption)
                            .foregroundStyle(workspaceLookupIsError ? Color.red : Color(.secondaryLabelColor))
                    }
                    TextField("CLI 路径", text: $supersetCLIPath)
                        .textFieldStyle(.roundedBorder)
                    Text("默认通过 PATH 调用 `superset`；也可以填写绝对路径。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if AIDispatchTarget(rawValue: dispatchTargetRaw) == .otty {
                    Text("请先在 Otty 设置中安装 CLI，并在“高级”中开启“IPC Allow Send Keys”。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TextField("命令模板", text: $dispatchTemplate, axis: .vertical)
                    .lineLimit(2...8)
                    .font(.system(.caption, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                Text("命令经 zsh 执行。可用变量：`$MARPLE_PROMPT_FILE`、`$MARPLE_CONTEXT_FILE`、`$MARPLE_VAULT_ROOT`、`$MARPLE_TITLE`、`$MARPLE_AGENT`、`$MARPLE_WORKSPACE`、`$MARPLE_RUN_SCRIPT`。`$MARPLE_RUN_SCRIPT` 是生成好的启动脚本：cd 到 vault 后把提示词交给代理。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("提示词模板") {
                PromptTemplateEditor(
                    title: AppPresentation.readerAIActionLabel(.reanalyze),
                    prompt: $readerAIReanalyzePrompt,
                    defaultPrompt: ReaderAIAction.reanalyze.defaultPromptIntent
                )
                PromptTemplateEditor(
                    title: AppPresentation.readerAIActionLabel(.format),
                    prompt: $readerAIFormatPrompt,
                    defaultPrompt: ReaderAIAction.format.defaultPromptIntent
                )
                PromptTemplateEditor(
                    title: AppPresentation.readerAIActionLabel(.translate),
                    prompt: $readerAITranslatePrompt,
                    defaultPrompt: ReaderAIAction.translate.defaultPromptIntent
                )
                PromptTemplateEditor(
                    title: AppPresentation.readerAIActionLabel(.discuss),
                    prompt: $readerAIDiscussPrompt,
                    defaultPrompt: ReaderAIAction.discuss.defaultPromptIntent
                )
                Text("支持变量：`{{action}}`、`{{target_relative_path}}`、`{{target_absolute_path}}`、`{{context_package_path}}`。Marple 会固定追加安全边界；格式整理会额外强制使用 quasi:audit-agent / quasi-audit。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("命令行接入") {
                Toggle("允许 marple-cli 接入", isOn: $enabled)
                Text("打开后,Marple 会在 ~/Library/Application Support/Marple/cli.sock 监听本机 AI 客户端。关闭时监听器不存在,资源占用为零。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            let resolvedTemplate = AIDispatchTarget.resolveTemplate(
                targetRawValue: dispatchTargetRaw,
                storedTemplate: dispatchTemplate
            )
            if resolvedTemplate != dispatchTemplate {
                dispatchTemplate = resolvedTemplate
            }
        }
    }

    @MainActor private func refreshSupersetWorkspaces() async {
        isLoadingWorkspaces = true
        workspaceLookupMessage = nil
        workspaceLookupIsError = false
        defer { isLoadingWorkspaces = false }

        do {
            let workspaces = try await ReaderAIRunner().listWorkspaces(cliPath: supersetCLIPath)
            discoveredWorkspaces = workspaces
            let ids = workspaces.map(\.id)
            if let first = workspaces.first {
                if supersetWorkspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !ids.contains(supersetWorkspaceID) {
                    supersetWorkspaceID = first.id
                }
                workspaceLookupMessage = workspaces.count == 1
                    ? String(localized: "已填入工作区 ID：\(first.displayName)")
                    : String(localized: "找到 \(workspaces.count) 个本机工作区，请选择一个。")
            } else {
                workspaceLookupIsError = true
                workspaceLookupMessage = String(localized: "没有找到本机 Superset 工作区。")
            }
        } catch let error as SupersetWorkspaceListError {
            workspaceLookupIsError = true
            workspaceLookupMessage = AppPresentation.supersetWorkspaceListErrorLabel(error)
            print("[marple] Superset workspace lookup FAILED: \(error)")
        } catch {
            workspaceLookupIsError = true
            workspaceLookupMessage = String(localized: "无法获取 Superset 工作区，请查看日志。")
            print("[marple] Superset workspace lookup FAILED: \(error)")
        }
    }
}

private struct SemanticIndexRefreshSettings: View {
    @ObservedObject var controller: SemanticIndexRefreshController
    @State private var confirmingRefresh = false

    var body: some View {
        if controller.isRunning {
            Text("正在刷新 \(controller.done)/\(controller.total)")
                .foregroundStyle(.secondary)
            if controller.total > 0 {
                ProgressView(value: Double(controller.done), total: Double(controller.total))
            } else {
                ProgressView()
            }
        } else if let error = controller.lastError {
            Text(error)
                .foregroundStyle(Color.red)
        } else if let result = controller.lastResult {
            Text("上次刷新：嵌入 \(result.embedded)，复用 \(result.reused)，共 \(result.total)")
                .foregroundStyle(.secondary)
            if let date = controller.lastCompletedAt {
                Text(AppDateFormatters.friendlyMinute.string(from: date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let existing = controller.existingIndex {
            Text("已有语义索引：\(existing.count) 条 · \(existing.dimension) 维")
                .foregroundStyle(.secondary)
            Text(existing.model)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let date = existing.updatedAt {
                Text("更新于 \(AppDateFormatters.friendlyMinute.string(from: date))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("尚未建立语义索引。")
                .foregroundStyle(.secondary)
        }
        Button(controller.isRunning ? String(localized: "刷新中…") : String(localized: "刷新语义索引")) {
            confirmingRefresh = true
        }
        .disabled(controller.isRunning)
        .confirmationDialog(
            "刷新语义索引？",
            isPresented: $confirmingRefresh,
            titleVisibility: .visible
        ) {
            Button("开始刷新") { controller.refreshNow(model: ActiveModel.current) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这是增量刷新：只会嵌入新增或内容变化的文档，并复用未变化的旧向量。运行期间会占用本机 MLX/GPU，可能耗时较久。不会从头重建；如需全量重建，请使用 CLI/手工维护路径。")
        }
        Text("仅手动增量刷新；不会跟随自动备份周期运行，也不在 UI 中提供从头重建。")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: - 备份

/// QUA-106: local APFS-snapshot backups. Mirrors the Ulysses panel — an enable
/// toggle, the fixed retention density, last-backup time, manual backup / browse
/// buttons, and a backup-location picker. Retention tiers and interval are
/// constants (not user-tunable) to keep the panel as simple as the reference.
private struct BackupSettings: View {
    @State private var scheduler: BackupScheduler?

    var body: some View {
        Group {
            if let scheduler {
                BackupSettingsContent(scheduler: scheduler)
            } else {
                Text("主窗口尚未就绪。").foregroundStyle(.secondary)
            }
        }
        .onAppear { scheduler = ActiveBackup.scheduler }
        .onReceive(NotificationCenter.default.publisher(for: ActiveBackup.didChangeNotification)) { note in
            scheduler = note.object as? BackupScheduler
        }
    }
}

private struct BackupSettingsContent: View {
    @ObservedObject private var scheduler: BackupScheduler
    @AppStorage(SettingsKeys.backupEnabled) private var enabled = true
    @AppStorage(SettingsKeys.backupLocation) private var location = ""
    @State private var footprint: SnapshotStore.Footprint?

    init(scheduler: BackupScheduler) {
        self.scheduler = scheduler
    }

    var body: some View {
        Form {
            Section("自动备份") {
                Toggle("备份已启用", isOn: $enabled)
                VStack(alignment: .leading, spacing: 2) {
                    Text("过去 7 天每天保留一份")
                    Text("过去 6 个月每周保留一份")
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            Section("最新备份") {
                Text(scheduler.lastBackup.map(Self.friendly) ?? String(localized: "尚未备份"))
                    .foregroundStyle(.secondary)
                if let fp = footprint, fp.snapshotCount > 0 {
                    Text("占用磁盘约 \(Self.formatBytes(fp.bytes)) · \(fp.snapshotCount) 份快照")
                        .foregroundStyle(.secondary)
                    Text("快照以 APFS 克隆共享磁盘块，实际占用约为一份快照；访达「显示简介」会重复累加共享块，显示数倍于此。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("立即备份") {
                        scheduler.backupNow()
                    }
                    Button("浏览备份…") {
                        BackupBrowserPresenter.shared.show()
                    }
                }
            }

            Section("备份位置") {
                HStack {
                    Text(displayLocation).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("更改…") { pickLocation() }
                    if !location.isEmpty {
                        Button("恢复默认") { location = "" }
                    }
                }
                Text("默认存于本机；改到外挂盘/网络盘会变成完整拷贝（无块去重）。云同步请同步文库本体而非备份目录。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: scheduler.lastBackup) {
            let store = scheduler.store
            footprint = await Task.detached { store.diskFootprint() }.value
        }
    }

    private static func formatBytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    private var displayLocation: String {
        location.isEmpty
            ? String(localized: "~/资源库/Application Support/Marple/Backups/")
            : (location as NSString).abbreviatingWithTildeInPath
    }

    private func pickLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "选择")
        if panel.runModal() == .OK, let url = panel.url {
            location = url.path
        }
    }

    private static func friendly(_ date: Date) -> String {
        AppDateFormatters.friendlyMinute.string(from: date)
    }
}
