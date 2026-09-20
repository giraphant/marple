import AppKit
import SwiftUI
import MarpleKit

// MARK: - Item identifiers

private extension NSToolbarItem.Identifier {
    static let toggleNav          = NSToolbarItem.Identifier("toggleNav")          // sidebar / list toggle
    static let readerSeparator    = NSToolbarItem.Identifier("readerSeparator")    // divider 1: content↔reader
    static let inspectorSeparator = NSToolbarItem.Identifier("inspectorSeparator") // divider 2: reader↔inspector
    static let back               = NSToolbarItem.Identifier("readerBack")
    static let forward            = NSToolbarItem.Identifier("readerForward")
    static let citation           = NSToolbarItem.Identifier("citation")
    static let original           = NSToolbarItem.Identifier("original")
    static let assistant          = NSToolbarItem.Identifier("assistant")
    static let openExternal       = NSToolbarItem.Identifier("openExternal")
    static let toggleInspector    = NSToolbarItem.Identifier("toggleInspector")
}

// MARK: - Closure-validated item

/// `NSToolbarItem` whose enablement is recomputed by a closure on each
/// autovalidation pass. NNW's `RSToolbarItem` walks the responder chain, but our
/// actions live on `AppModel` (not a responder), so we validate directly. Handles
/// both image-based items and view-based (custom NSButton) items.
final class ValidatingToolbarItem: NSToolbarItem {
    var isEnabledProvider: (() -> Bool)?
    override func validate() {
        let on = isEnabledProvider?() ?? true
        isEnabled = on
        (view as? NSControl)?.isEnabled = on
    }
}

// MARK: - Toolbar controller

/// Builds the window's `NSToolbar` the way Mail / NetNewsWire do: a flat ordered
/// list with `NSTrackingSeparatorToolbarItem`s locked to split dividers, so items
/// land over the column they act on. The reader's right-side actions live in one
/// joined `NSToolbarItemGroup` (引用 | 原文 | 助手 | 外部编辑器).
@MainActor
final class MarpleToolbarController: NSObject, NSToolbarDelegate, NSMenuDelegate {
    weak var model: AppModel?
    weak var splitView: NSSplitView?
    weak var shell: MarpleSplitViewController?

    // Reused so menuNeedsUpdate can tell them apart (NSMenu has no stable identifier).
    private lazy var citationMenu: NSMenu = { let m = NSMenu(); m.delegate = self; return m }()
    private lazy var originalMenu: NSMenu = { let m = NSMenu(); m.delegate = self; return m }()
    private lazy var assistantMenu: NSMenu = { let m = NSMenu(); m.delegate = self; return m }()

    func makeToolbar() -> NSToolbar {
        let tb = NSToolbar(identifier: "MarpleMainToolbar")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = false
        tb.autosavesConfiguration = false
        return tb
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .flexibleSpace,              // push the toggle to the sidebar's right edge
            .toggleNav,
            .sidebarTrackingSeparator,   // divider 0 (sidebar↔list), system-managed
            .readerSeparator,            // divider 1 (list↔reader): back/forward at reader's left
            .back,
            .forward,
            .flexibleSpace,
            // Four adjacent view-based items; macOS auto-groups them into one glass
            // well (the NetNewsWire pattern — no NSToolbarItemGroup).
            .citation,
            .original,
            .assistant,
            .openExternal,
            .inspectorSeparator,         // divider 2 (reader↔inspector)
            .toggleInspector,            // sits over the inspector
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .toggleNav:
            return iconItem(id, "sidebar.leading", String(localized: "切换边栏"), #selector(toggleNav)) { true }
        case .readerSeparator:
            guard let splitView, splitView.arrangedSubviews.count >= 3 else { return nil }
            return NSTrackingSeparatorToolbarItem(identifier: .readerSeparator,
                                                  splitView: splitView, dividerIndex: 1)
        case .inspectorSeparator:
            guard let splitView, splitView.arrangedSubviews.count >= 4 else { return nil }
            return NSTrackingSeparatorToolbarItem(identifier: .inspectorSeparator,
                                                  splitView: splitView, dividerIndex: 2)
        case .back:
            return iconItem(id, "chevron.left", String(localized: "后退"), #selector(goBack)) { [weak self] in
                self?.model?.canGoBack ?? false
            }
        case .forward:
            return iconItem(id, "chevron.right", String(localized: "前进"), #selector(goForward)) { [weak self] in
                self?.model?.canGoForward ?? false
            }
        case .toggleInspector:
            return iconItem(id, "sidebar.trailing", String(localized: "检查器"), #selector(toggleInspector)) { [weak self] in
                self?.model?.openPath != nil
            }
        case .citation:
            return buttonItem(id, "quote.bubble", String(localized: "复制引用 · 右键选格式"),
                              #selector(citationPrimary(_:)), menu: citationMenu) { [weak self] in
                self?.model?.openCitationEntry != nil
            }
        case .original:
            return buttonItem(id, "doc.richtext", String(localized: "阅读原文 · 右键打开译本"),
                              #selector(originalPrimary(_:)), menu: originalMenu) { [weak self] in
                self?.model?.canOpenPDF ?? false
            }
        case .assistant:
            return buttonItem(id, "sparkles", String(localized: "AI 助手"), #selector(assistantPrimary(_:)), menu: assistantMenu) { [weak self] in
                self?.model?.openPath != nil
            }
        case .openExternal:
            return buttonItem(id, "arrow.up.forward.square", String(localized: "用外部编辑器打开"),
                              #selector(openExternal)) { [weak self] in
                self?.model?.openPath != nil
            }
        default:
            return nil   // system identifiers (toggleSidebar / sidebarTrackingSeparator / spaces)
        }
    }

    // MARK: Item builders

    /// Image-based toolbar item (standalone buttons: nav/back/forward/inspector).
    private func iconItem(_ id: NSToolbarItem.Identifier, _ symbol: String, _ help: String,
                          _ action: Selector, _ enabled: @escaping () -> Bool) -> NSToolbarItem {
        let item = ValidatingToolbarItem(itemIdentifier: id)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        item.label = help
        item.toolTip = help
        item.isBordered = true
        item.target = self
        item.action = action
        item.autovalidates = true
        item.isEnabledProvider = enabled
        return item
    }

    /// View-based item, mirroring NetNewsWire's `buildToolbarButton`: a textured-round
    /// `NSButton` (which has an intrinsic size, unlike a borderless one) hosted in the
    /// item. Standalone + adjacent → macOS auto-groups them into one glass well. The
    /// button's `menu` provides the right-click secondary actions (no ▾ indicator).
    private func buttonItem(_ id: NSToolbarItem.Identifier, _ symbol: String, _ help: String,
                            _ action: Selector, menu: NSMenu? = nil,
                            enabled: @escaping () -> Bool) -> NSToolbarItem {
        let item = ValidatingToolbarItem(itemIdentifier: id)
        item.autovalidates = true
        let button = NSButton()
        button.bezelStyle = .texturedRounded
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.imageScaling = .scaleProportionallyDown
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.menu = menu   // right-click
        item.view = button
        item.label = help
        item.toolTip = help
        item.isEnabledProvider = enabled
        return item
    }

    // MARK: Actions

    @objc private func toggleNav()       { shell?.toggleNavigation() }
    @objc private func goBack()          { Task { await model?.goBack() } }
    @objc private func goForward()       { Task { await model?.goForward() } }
    @objc private func toggleInspector() { model?.inspectorVisible.toggle() }
    @objc private func openExternal()    { Task { await model?.openExternally() } }
    @objc private func readOriginal()    { Task { await model?.openPDF() } }
    @objc private func readTranslation() { Task { await model?.openTranslation() } }

    @objc private func assistantPrimary(_ sender: NSButton) {
        assistantMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func reanalyzeWithReaderAI() {
        Task { await model?.runReaderAIAction(.reanalyze) }
    }

    @objc private func formatWithReaderAI() {
        Task { await model?.runReaderAIAction(.format) }
    }

    @objc private func translateWithReaderAI() {
        Task { await model?.runReaderAIAction(.translate) }
    }

    @objc private func discussWithReaderAI() {
        Task { await model?.runReaderAIAction(.discuss) }
    }

    /// Click on 引用: per the setting, copy the default format or pop the menu.
    @objc private func citationPrimary(_ sender: NSButton) {
        let mode = CitationClickAction(
            rawValue: UserDefaults.standard.string(forKey: SettingsKeys.citationClickAction) ?? "")
            ?? .copyDefault
        if mode == .showMenu {
            citationMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
        } else {
            copyCitation(format: defaultCitationFormat())
        }
    }

    /// Click on 原文: per the setting, open the original PDF or pop the menu.
    @objc private func originalPrimary(_ sender: NSButton) {
        let mode = OriginalClickAction(
            rawValue: UserDefaults.standard.string(forKey: SettingsKeys.originalClickAction) ?? "")
            ?? .openOriginal
        if mode == .showMenu {
            originalMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
        } else {
            Task { await model?.openPDF() }
        }
    }

    // MARK: Menus (rebuilt on open so they track the current doc + default)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === citationMenu { buildCitationMenu(menu) }
        else if menu === originalMenu { buildOriginalMenu(menu) }
        else if menu === assistantMenu { buildAssistantMenu(menu) }
    }

    private func buildCitationMenu(_ menu: NSMenu) {
        guard model?.openCitationEntry != nil else { return }
        let def = defaultCitationFormat()
        for f in CitationFormat.allCases {
            let mi = NSMenuItem(title: AppPresentation.citationFormatLabel(f), action: #selector(copyCitationFromMenu(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = f.rawValue
            if f == def { mi.state = .on }
            menu.addItem(mi)
        }
    }

    private func buildOriginalMenu(_ menu: NSMenu) {
        guard model?.canOpenPDF == true else { return }
        let read = NSMenuItem(title: String(localized: "阅读原文"), action: #selector(readOriginal), keyEquivalent: "")
        read.target = self
        menu.addItem(read)
        if model?.canOpenTranslation == true {
            let tr = NSMenuItem(title: String(localized: "打开译本"), action: #selector(readTranslation), keyEquivalent: "")
            tr.target = self
            menu.addItem(tr)
        }
    }

    private func buildAssistantMenu(_ menu: NSMenu) {
        let reanalyze = NSMenuItem(title: AppPresentation.readerAIActionLabel(.reanalyze),
                                   action: #selector(reanalyzeWithReaderAI),
                                   keyEquivalent: "")
        reanalyze.target = self
        reanalyze.isEnabled = model?.openPath != nil
        menu.addItem(reanalyze)

        let format = NSMenuItem(title: AppPresentation.readerAIActionLabel(.format),
                                action: #selector(formatWithReaderAI),
                                keyEquivalent: "")
        format.target = self
        format.isEnabled = model?.openPath != nil
        menu.addItem(format)

        let translate = NSMenuItem(title: AppPresentation.readerAIActionLabel(.translate),
                                   action: #selector(translateWithReaderAI),
                                   keyEquivalent: "")
        translate.target = self
        translate.isEnabled = model?.openPath != nil
        menu.addItem(translate)

        let discuss = NSMenuItem(title: AppPresentation.readerAIActionLabel(.discuss),
                                 action: #selector(discussWithReaderAI),
                                 keyEquivalent: "")
        discuss.target = self
        discuss.isEnabled = model?.openPath != nil
        menu.addItem(discuss)
    }

    private func defaultCitationFormat() -> CitationFormat {
        CitationFormat(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.citationFormat) ?? "")
            ?? .inlineEN
    }

    @objc private func copyCitationFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let f = CitationFormat(rawValue: raw) else { return }
        copyCitation(format: f)
    }

    private func copyCitation(format: CitationFormat) {
        guard let e = model?.openCitationEntry else { return }
        let text = buildCitation(e, format: format)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model?.flash(String(localized: "已复制引用 · \(AppPresentation.citationFormatLabel(format))"))
    }
}
