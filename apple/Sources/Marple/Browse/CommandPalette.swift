import SwiftUI
import AppKit
import MarpleKit

/// One scored palette row (entry + relevance + match source for the badge).
struct PaletteResult: Sendable {
    let entry: Entry
    let score: Double
    let source: String?
}

/// Arc/Xcode-style command palette (⌘T): a cross-type search hosted in a floating
/// `NSPanel` (see `CommandPalettePanel`). Mirrors the web `CommandPalette.tsx`
/// (mode segmented control + Tab cycle, per-type top-5 + "查看全部", ↑/↓ ⏎ ⌘⏎ Esc,
/// "/" hops across type sections, relevance badges) and CodeEdit's panel patterns (hidden `.keyboardShortcut`
/// buttons for nav so they coexist with the focused field; focus comes from the
/// key panel, not a SwiftUI hack). 快速 = in-memory ranker, 平衡 = FTS, 深度 =
/// semantic vectors (disabled until the vector index and MLX runtime are ready).
struct CommandPalette: View {
    @Bindable var model: AppModel
    let onClose: () -> Void

    @State private var query = ""
    @State private var mode: SearchMode = .fast
    // Computed once per (debounced) search, NOT per keystroke render — sectioning
    // over *all* matches in `body` made typing janky.
    @State private var sections: [PaletteSection] = []
    // Already-open tabs whose entry matched this search — shown as an Arc-style
    // "切换到标签页" section above the type sections (de-duped by path).
    @State private var openMatches: [Entry] = []
    @State private var sourceByPath: [String: String] = [:]
    @State private var loading = false
    @State private var selected = 0
    // Only keyboard nav (↑/↓) should auto-scroll to the selection. Hover also
    // moves `selected` (for highlight), but must NOT scroll — else the scroll
    // slides a new row under the stationary cursor, which re-fires .onHover and
    // the list drifts uncontrollably.
    @State private var scrollToSelection = false
    // Cursor position captured at the last ↑/↓. A hover firing while the cursor
    // is still here was triggered by the list scrolling under a stationary mouse,
    // not a real move — honoring it would yank `selected` back to the row under
    // the cursor, so keyboard nav appears stuck. We ignore those (see .onHover).
    @State private var keyboardNavCursor: NSPoint?
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

    private let perType = 5

    /// Mode-segment label. Glyphs at equal point size *measure* the same as the
    /// placeholder, but medium weight + dark color + the pill background read a
    /// size bigger — so the segments sit one step below the placeholder's body(15).
    private static let modeFont = Font.system(size: 13, weight: .medium)

    private var promoteType: EntryType? {
        if case .type(let t) = model.browsePane { return t } else { return nil }
    }

    // Open-tab matches sit first so keyboard nav lands on them before the type
    // sections (mirrors their visual order).
    private var flat: [Entry] { openMatches + sections.flatMap { $0.top } }

    private var hasQuery: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            if hasQuery {
                Divider()
                results
                    .frame(height: 420)
            }
        }
        .frame(width: 640)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
        )
        .ignoresSafeArea()
        // Bare arrows/Tab aren't delivered to hidden `.keyboardShortcut` buttons;
        // `.onKeyPress` on the focused panel catches them. Enter is the field's
        // onSubmit; Esc closes.
        .onKeyPress(.escape) { onClose(); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        // "/" hops to the next type section, ⇧/ back (QUA-197). A switch-flavored
        // key that never appears in a title/author query — the palette trades away
        // typing a literal "/" so the hop needs no modifier. (Arrows were tried
        // first and clashed with caret movement in the field.)
        .onKeyPress(keys: ["/", "?"]) { press in
            let back = press.key == "?" || press.modifiers.contains(.shift)
            jumpSection(back ? -1 : 1)
            return .handled   // never insert "/" — consistent whether or not results exist
        }
        .onKeyPress(.tab) { cycleMode(); return .handled }
        .onAppear {
            runSearch()
            // Proven pattern (Maccy/CotEditor): @FocusState in onAppear, once the
            // panel is key. The async nudge guards against NSHostingView settling
            // a beat after appear.
            DispatchQueue.main.async { fieldFocused = true }
        }
        .onChange(of: query) { _, _ in runSearch() }
        // A mode switch re-runs immediately (no debounce) so Tab swaps to the new
        // engine's results right away, instead of lingering on the previous list.
        // Results stay in place and update when ready (CodeEdit/Raycast behavior);
        // the header spinner is the "working" signal for slow modes.
        .onChange(of: mode) { _, _ in runSearch(debounce: false) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Space.s4) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            modeControl

            // Custom placeholder overlay: the native prompt always renders at the
            // field's own font (title3), too loud for a hint line — draw it one
            // size down instead. (Mode names live in the segmented control, so
            // the prompt is just scope + key hints.)
            ZStack(alignment: .leading) {
                if query.isEmpty {
                    Text(mode.placeholder)
                        .font(Typo.body)
                        .foregroundStyle(Color(nsColor: .placeholderTextColor))
                        .allowsHitTesting(false)
                }
                TextField("", text: $query)
                    .textFieldStyle(.plain)
                    .font(Typo.title3)
                    .focused($fieldFocused)
                    .onSubmit { activate(selected) }
            }

            if loading {
                ProgressView().controlSize(.small)
            }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清空")
            }
        }
        .padding(.horizontal, Space.s5)
        .padding(.vertical, Space.s5)
    }

    private var modeControl: some View {
        HStack(spacing: 2) {
            ForEach(SearchMode.allCases, id: \.self) { m in
                let disabled = (m == .deep && !model.semanticAvailable)   // 深度 needs the vector index
                Button { if !disabled { mode = m } } label: {
                    Text(m.label)
                        .font(Self.modeFont)
                        .padding(.horizontal, Space.s4)
                        .padding(.vertical, Space.s2)
                        .background(mode == m ? Color.accentColor : Color.clear)
                        .foregroundStyle(modeForeground(m, disabled: disabled))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .help(disabled ? "深度检索需要向量索引和 MLX 运行时" : "Tab 切换模式")
            }
        }
        .padding(2)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func modeForeground(_ m: SearchMode, disabled: Bool) -> Color {
        if mode == m { return .white }
        return disabled ? Color.secondary.opacity(0.5) : .secondary
    }

    // MARK: Results

    @ViewBuilder private var results: some View {
        if mode == .deep && !model.semanticAvailable {
            placeholder("深度检索需要向量索引和 MLX 运行时")
        } else if sections.isEmpty && openMatches.isEmpty {
            placeholder(loading ? "搜索中…" : "没有匹配的条目")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        if !openMatches.isEmpty { switchSection }
                        ForEach(Array(sectionBases), id: \.section.id) { item in
                            sectionView(item.section, base: item.base)
                        }
                    }
                }
                .onChange(of: selected) { _, new in
                    guard scrollToSelection else { return }
                    scrollToSelection = false
                    guard flat.indices.contains(new) else { return }
                    proxy.scrollTo(flat[new].path, anchor: .center)
                }
            }
        }
    }

    /// Pair each section with the flat index of its first row (for ↑/↓ tracking).
    /// The open-tab matches occupy the first `openMatches.count` flat slots.
    private var sectionBases: [(section: PaletteSection, base: Int)] {
        var out: [(PaletteSection, Int)] = []
        var n = openMatches.count
        for s in sections { out.append((s, n)); n += s.top.count }
        return out
    }

    /// Arc-style "switch to an already-open tab" group, pinned above the results.
    private var switchSection: some View {
        Section {
            ForEach(Array(openMatches.enumerated()), id: \.element.path) { offset, entry in
                row(entry, index: offset, isOpenTab: true)
            }
        } header: {
            HStack(spacing: Space.s3) {
                Image(systemName: "arrow.right.square")
                    .foregroundStyle(Color.accentColor)
                Text("切换到标签页").font(Typo.caption).foregroundStyle(.primary)
                Text("(\(openMatches.count))").font(Typo.caption2).foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
            }
            .padding(.horizontal, Space.s5)
            .padding(.vertical, Space.s2)
            .background(.thinMaterial)
        }
    }

    private func sectionView(_ section: PaletteSection, base: Int) -> some View {
        Section {
            ForEach(Array(section.top.enumerated()), id: \.element.path) { offset, entry in
                row(entry, index: base + offset)
            }
            if section.total > section.top.count {
                Button {
                    onClose()
                    model.paletteViewAll(type: section.type, query: query)
                } label: {
                    Text("在「\(section.type.label)」中查看全部 \(section.total) 条 →")
                        .font(Typo.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Space.s5)
                        .padding(.vertical, Space.s3)
                }
                .buttonStyle(.plain)
            }
        } header: {
            HStack(spacing: Space.s3) {
                TypeBadge(type: section.type, size: 16)
                Text(section.type.label).font(Typo.caption).foregroundStyle(.primary)
                Text("(\(section.total))").font(Typo.caption2).foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
            }
            .padding(.horizontal, Space.s5)
            .padding(.vertical, Space.s2)
            .background(.thinMaterial)
        }
    }

    private func row(_ entry: Entry, index: Int, isOpenTab: Bool = false) -> some View {
        let isSel = index == selected
        return HStack(spacing: Space.s4) {
            TypeBadge(type: entry.type, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Space.s3) {
                    Text(entry.title ?? fileStem(entry.path))
                        .font(Typo.body)
                        .lineLimit(1)
                    if let badge = searchSourceBadge(sourceByPath[entry.path]) {
                        Text(badge)
                            .font(Typo.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.18),
                                        in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(metaLine(entry))
                    .font(Typo.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isOpenTab {
                Image(systemName: "arrow.right")
                    .font(Typo.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, Space.s5)
        .padding(.vertical, Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSel ? Color.accentColor.opacity(0.15) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            guard hovering else { return }
            // Scroll-under-stationary-cursor: the pointer hasn't moved since the
            // last ↑/↓, so this hover is the scroll passing a row beneath it —
            // ignore it so keyboard nav can advance past the row under the mouse.
            if let c = keyboardNavCursor, NSEvent.mouseLocation == c { return }
            keyboardNavCursor = nil
            scrollToSelection = false
            selected = index
        }
        .onTapGesture { activate(index) }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(Typo.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Behavior

    private func clearResults() {
        sections = []
        openMatches = []
        sourceByPath = [:]
        selected = 0
    }

    private func runSearch(debounce: Bool = true) {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { clearResults(); loading = false; return }
        loading = true
        let currentMode = mode
        let promote = promoteType
        // After QUA-96 the fast ranker is ~5 ms median, so debouncing fast-mode
        // keystrokes just adds visible drag. FTS / vector still cost real time
        // (network + embed compute) — keep their tail-debounce.
        let debounceNs: UInt64 = !debounce ? 0 : (currentMode == .fast ? 0 : 140_000_000)
        searchTask = Task {
            if debounceNs > 0 {
                try? await Task.sleep(nanoseconds: debounceNs)
                if Task.isCancelled { return }
            }
            let result = await model.commandSearch(q, mode: currentMode)
            if Task.isCancelled { return }
            // Pull matched-and-already-open docs into the "switch to tab" group so
            // picking one jumps to the existing tab; the rest section normally.
            let openSet = model.openTabPaths
            var seenOpen = Set<String>()
            let opens = openSet.isEmpty ? [] : result.filter {
                openSet.contains($0.entry.path) && seenOpen.insert($0.entry.path).inserted
            }
            let rest = openSet.isEmpty ? result : result.filter { !openSet.contains($0.entry.path) }
            let secs = paletteSections(rest.map { (entry: $0.entry, score: $0.score) },
                                       order: model.typeOrder, promote: promote, perType: perType,
                                       minimumInlineScoreRatio: currentMode.paletteInlineScoreFloorRatio)
            var src: [String: String] = [:]
            for r in result where r.source != nil { src[r.entry.path] = r.source }
            openMatches = opens.prefix(perType).map(\.entry)
            sections = secs
            sourceByPath = src
            selected = 0
            loading = false
        }
    }

    private func cycleMode() {
        // Tab cycles fast → balanced → (深度, once the vector index exists) → fast.
        var next = mode.next()
        if next == .deep && !model.semanticAvailable { next = next.next() }
        mode = next
    }

    private func move(_ delta: Int) {
        guard !flat.isEmpty else { return }
        keyboardNavCursor = NSEvent.mouseLocation
        scrollToSelection = true
        selected = min(max(0, selected + delta), flat.count - 1)
    }

    /// Jump the selection to the first row of the next/previous section (the
    /// open-tab group counts as one), wrapping at the ends — "/" is a cycler,
    /// so a few presses always tour every type.
    private func jumpSection(_ delta: Int) {
        guard !flat.isEmpty else { return }
        // First-row flat index of every non-empty section, in visual order.
        var bases: [Int] = openMatches.isEmpty ? [] : [0]
        bases.append(contentsOf: sectionBases.compactMap { $0.section.top.isEmpty ? nil : $0.base })
        guard bases.count > 1 else { return }
        // Section containing the current selection → step from there.
        let current = bases.lastIndex { $0 <= selected } ?? 0
        let target = (current + delta + bases.count) % bases.count
        keyboardNavCursor = NSEvent.mouseLocation
        scrollToSelection = true
        selected = bases[target]
    }

    /// Activate the row at `index`: an open-tab match switches to its existing tab,
    /// anything else opens in a NEW tab. ⌘T is a "find & open" action, so opening
    /// must never replace whatever the current tab is showing — but switching to a
    /// tab the user already has open is exactly what they asked for (Arc-style).
    private func activate(_ index: Int) {
        guard flat.indices.contains(index) else { return }
        let entry = flat[index]
        onClose()
        if index < openMatches.count {
            Task { await model.switchToOpenTab(path: entry.path) }
        } else {
            Task { await model.openFromPalette(entry.path, newTab: true) }
        }
    }

    private func fileStem(_ path: String) -> String {
        (path.split(separator: "/").last.map(String.init) ?? path)
            .replacingOccurrences(of: ".md", with: "")
    }

    private func metaLine(_ entry: Entry) -> String {
        var parts = [entry.type.label]
        if !entry.author.isEmpty { parts.append(entry.author.joined(separator: ", ")) }
        if let y = entry.year, !y.isEmpty { parts.append(y) }
        return parts.joined(separator: " · ")
    }
}
