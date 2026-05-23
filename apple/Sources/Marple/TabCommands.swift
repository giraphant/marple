import SwiftUI
import MarpleKit

// Classic FocusedValueKey (the @Entry macro needs a newer SDK than these Command
// Line Tools ship). RootView publishes the model via .focusedSceneValue.
private struct AppModelFocusKey: FocusedValueKey { typealias Value = AppModel }

extension FocusedValues {
    var appModel: AppModel? {
        get { self[AppModelFocusKey.self] }
        set { self[AppModelFocusKey.self] = newValue }
    }
}

/// The 标签 menu: tab + history shortcuts, reachable from anywhere in the focused
/// window via @FocusedValue.
struct TabCommands: Commands {
    @FocusedValue(\.appModel) private var model

    var body: some Commands {
        CommandMenu("标签") {
            Button("新建标签") { run { await $0.newTab() } }
                .keyboardShortcut("t", modifiers: .command)
            Button("关闭标签") { run { await $0.closeActiveTab() } }
                .keyboardShortcut("w", modifiers: .command)
                .disabled((model?.tabs.count ?? 0) <= 1)

            Divider()

            Button("后退") { run { await $0.goBack() } }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!(model?.canGoBack ?? false))
            Button("前进") { run { await $0.goForward() } }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!(model?.canGoForward ?? false))

            Divider()

            Button("下一个标签") { run { await $0.selectNextTab() } }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("上一个标签") { run { await $0.selectPrevTab() } }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])

            Divider()

            ForEach(1...9, id: \.self) { n in
                Button("选择标签 \(n)") { run { await $0.selectTab(index: n - 1) } }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }
        }
    }

    private func run(_ action: @escaping (AppModel) async -> Void) {
        guard let model else { return }
        Task { await action(model) }
    }
}
