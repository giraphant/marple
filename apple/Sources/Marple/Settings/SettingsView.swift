import SwiftUI
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
        }
        .frame(width: 480, height: 380)
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

    var body: some View {
        Form {
            Section("命令行接入") {
                Toggle("允许 marple-cli 接入", isOn: $enabled)
                Text("打开后,Marple 会在 ~/Library/Application Support/Marple/cli.sock 监听本机 AI 客户端。关闭时监听器不存在,资源占用为零。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
