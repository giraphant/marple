import SwiftUI
import AppKit
import MarpleKit

/// The 页面 menu: tab + history shortcuts. The main window is AppKit-owned, which
/// SwiftUI's `@FocusedValue` can't reach, so these read the global `ActiveModel`
/// (Marple is single-window). Actions are guarded, so always-enabled items are safe.
struct TabCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建笔记") { run { await $0.newIdeaNote() } }
                .keyboardShortcut("n", modifiers: .command)
        }

        // Global search lives next to 新建笔记 in 文件 (the Ulysses quick-open
        // spot) — it's a library action, not a page-navigation one.
        CommandGroup(after: .newItem) {
            Button("搜索…") { if let m = ActiveModel.current { CommandPalettePresenter.toggle(model: m) } }
                .keyboardShortcut("t", modifiers: .command)
        }

        // Replace the standard File close group so plain ⌘W closes a tab (not the
        // window); window-close relocates to ⇧⌘W. (Pattern from CodeEdit.)
        CommandGroup(replacing: .saveItem) {
            Button("关闭页面") {
                if let m = ActiveModel.current, m.tabs.count > 1 {
                    Task { await m.closeActiveTab() }
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w", modifiers: .command)

            Button("关闭窗口") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.shift, .command])
        }

        CommandMenu("页面") {
            Button("后退") { run { await $0.goBack() } }
                .keyboardShortcut("[", modifiers: .command)
            Button("前进") { run { await $0.goForward() } }
                .keyboardShortcut("]", modifiers: .command)

            Divider()

            Button("下一个页面") { run { await $0.selectNextTab() } }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("上一个页面") { run { await $0.selectPrevTab() } }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])

            Divider()

            ForEach(1...9, id: \.self) { n in
                Button("选择页面 \(n)") { run { await $0.selectTab(index: n - 1) } }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }
        }

    }

    private func run(_ action: @escaping (AppModel) async -> Void) {
        guard let m = ActiveModel.current else { return }
        Task { await action(m) }
    }
}
