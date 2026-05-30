import SwiftUI
import AppKit
import MarpleKit

/// The macOS preferences window (⌘,). Three tabs mirror the web SettingsPanel,
/// minus the parts that don't apply to a pure native reader (in-app editor toggle,
/// LLM-body editing) or aren't built yet (semantic vectors / Phase 3).
struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettings()
                .tabItem { Label("外观", systemImage: "paintbrush") }
            ReadingSettings()
                .tabItem { Label("阅读", systemImage: "textformat") }
            ToolbarSettings()
                .tabItem { Label("工具栏", systemImage: "hand.tap") }
            AIBridgeSettings()
                .tabItem { Label("AI 接入", systemImage: "terminal") }
            BackupSettings()
                .tabItem { Label("备份", systemImage: "clock.arrow.circlepath") }
        }
        .frame(width: 620, height: 560)
    }
}

// MARK: - 外观

private struct AppearanceSettings: View {
    @AppStorage(SettingsKeys.theme) private var theme = ThemePreference.system

    var body: some View {
        Form {
            Picker("主题", selection: $theme) {
                ForEach(ThemePreference.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .padding(20)
    }
}

// MARK: - 阅读

private struct ReadingSettings: View {
    @AppStorage(SettingsKeys.readingFontFamily) private var family = ReadingFontFamily.sans
    @AppStorage(SettingsKeys.readingFontSize) private var size = ReadingDefaults.fontSize
    @AppStorage(SettingsKeys.readingLineHeight) private var lineHeight = ReadingDefaults.lineHeight
    @AppStorage(SettingsKeys.readingLetterSpacing) private var letterSpacing = ReadingDefaults.letterSpacing
    @AppStorage(SettingsKeys.externalEditor) private var editor = ""

    var body: some View {
        Form {
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

            Section("外部编辑器") {
                EditorPicker(value: $editor)
                Text("用应用名打开（`open -a`）；留空则用系统默认 `.md` 程序。改动立即生效。")
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
                    Button(preset.label) { value = preset.app }
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

// MARK: - 工具栏

private struct ToolbarSettings: View {
    @AppStorage(SettingsKeys.citationFormat) private var format = CitationFormat.inlineEN
    @AppStorage(SettingsKeys.citationClickAction) private var citationClick = CitationClickAction.copyDefault
    @AppStorage(SettingsKeys.originalClickAction) private var originalClick = OriginalClickAction.openOriginal

    var body: some View {
        Form {
            Section("按钮点击行为") {
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
                    ForEach(CitationFormat.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                Text("示例：\(format.example)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - AI 接入

/// QUA-107: opt-in switch for the local CLI socket server. Off by default so
/// nothing runs unless the user explicitly turns it on; toggling here flips
/// the listener live (no relaunch needed).
private struct AIBridgeSettings: View {
    @AppStorage(SettingsKeys.cliServerEnabled) private var enabled = false
    @AppStorage(SettingsKeys.supersetWorkspaceID) private var supersetWorkspaceID = ""
    @AppStorage(SettingsKeys.supersetAgent) private var supersetAgent = "claude"
    @AppStorage(SettingsKeys.supersetCLIPath) private var supersetCLIPath = "superset"
    @AppStorage(SettingsKeys.supersetReanalyzePrompt) private var supersetReanalyzePrompt = ""
    @AppStorage(SettingsKeys.supersetFormatPrompt) private var supersetFormatPrompt = ""
    @State private var discoveredWorkspaces: [SupersetWorkspace] = []
    @State private var workspaceLookupMessage: String?
    @State private var workspaceLookupIsError = false
    @State private var isLoadingWorkspaces = false

    var body: some View {
        Form {
            Section("Reader AI 助手") {
                HStack {
                    TextField("Superset workspace ID", text: $supersetWorkspaceID)
                        .textFieldStyle(.roundedBorder)
                    Button(isLoadingWorkspaces ? "获取中…" : "获取") {
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
                TextField("Agent", text: $supersetAgent)
                    .textFieldStyle(.roundedBorder)
                TextField("CLI 路径", text: $supersetCLIPath)
                    .textFieldStyle(.roundedBorder)
                Text("默认通过 PATH 调用 `superset`；也可以填写绝对路径。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("AI 咒语") {
                PromptTemplateEditor(
                    title: SupersetAction.reanalyze.label,
                    prompt: $supersetReanalyzePrompt,
                    defaultPrompt: SupersetAction.reanalyze.defaultPromptIntent
                )
                PromptTemplateEditor(
                    title: SupersetAction.format.label,
                    prompt: $supersetFormatPrompt,
                    defaultPrompt: SupersetAction.format.defaultPromptIntent
                )
                Text("支持变量：`{{action}}`、`{{target_relative_path}}`、`{{target_absolute_path}}`、`{{context_package_path}}`。Marple 会固定追加安全边界：先读上下文包，只编辑目标文件。")
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
    }

    @MainActor private func refreshSupersetWorkspaces() async {
        isLoadingWorkspaces = true
        workspaceLookupMessage = nil
        workspaceLookupIsError = false
        defer { isLoadingWorkspaces = false }

        do {
            let workspaces = try await SupersetRunner().listWorkspaces(cliPath: supersetCLIPath)
            discoveredWorkspaces = workspaces
            let ids = workspaces.map(\.id)
            if let first = workspaces.first {
                if supersetWorkspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !ids.contains(supersetWorkspaceID) {
                    supersetWorkspaceID = first.id
                }
                workspaceLookupMessage = workspaces.count == 1 ? "已填入 workspace ID：\(first.displayName)" : "找到 \(workspaces.count) 个本机 workspace，请选择一个。"
            } else {
                workspaceLookupIsError = true
                workspaceLookupMessage = "没有找到本机 Superset workspace。"
            }
        } catch let error as SupersetWorkspaceListError {
            workspaceLookupIsError = true
            workspaceLookupMessage = error.friendlyMessage
            print("[marple] Superset workspace lookup FAILED: \(error)")
        } catch {
            workspaceLookupIsError = true
            workspaceLookupMessage = "无法获取 Superset workspace，请查看日志。"
            print("[marple] Superset workspace lookup FAILED: \(error)")
        }
    }
}

// MARK: - 备份

/// QUA-106: local APFS-snapshot backups. Mirrors the Ulysses panel — an enable
/// toggle, the fixed retention density, last-backup time, manual backup / browse
/// buttons, and a backup-location picker. Retention tiers and interval are
/// constants (not user-tunable) to keep the panel as simple as the reference.
private struct BackupSettings: View {
    @AppStorage(SettingsKeys.backupEnabled) private var enabled = true
    @AppStorage(SettingsKeys.backupLocation) private var location = ""
    @State private var lastBackup: Date?
    @State private var footprint: SnapshotStore.Footprint?

    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("自动备份") {
                Toggle("备份已启用", isOn: $enabled)
                VStack(alignment: .leading, spacing: 2) {
                    Text("过去 12 小时每小时保留一份")
                    Text("过去 7 天每天保留一份")
                    Text("过去 6 个月每周保留一份")
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            Section("最新备份") {
                Text(lastBackup.map(Self.friendly) ?? "尚未备份")
                    .foregroundStyle(.secondary)
                if let fp = footprint, fp.snapshotCount > 0 {
                    Text("占用磁盘约 \(Self.formatBytes(fp.bytes)) · \(fp.snapshotCount) 份快照")
                        .foregroundStyle(.secondary)
                    Text("快照以 APFS 克隆共享磁盘块，实际占用约为一份快照；访达「显示简介」会重复累加共享块，显示数倍于此。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("立即备份") {
                        ActiveBackup.scheduler?.backupNow()
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
        .onAppear { lastBackup = ActiveBackup.scheduler?.lastBackup }
        .onReceive(tick) { _ in lastBackup = ActiveBackup.scheduler?.lastBackup }
        .task(id: lastBackup) {
            guard let store = ActiveBackup.scheduler?.store else { footprint = nil; return }
            footprint = await Task.detached { store.diskFootprint() }.value
        }
    }

    private static func formatBytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    private var displayLocation: String {
        location.isEmpty
            ? "~/资源库/Application Support/Marple/Backups/"
            : (location as NSString).abbreviatingWithTildeInPath
    }

    private func pickLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            location = url.path
        }
    }

    private static func friendly(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}
