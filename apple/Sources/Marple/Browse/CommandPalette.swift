import SwiftUI
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
/// relevance badges) and CodeEdit's panel patterns (hidden `.keyboardShortcut`
/// buttons for nav so they coexist with the focused field; focus comes from the
/// key panel, not a SwiftUI hack). 快速 = in-memory ranker, 平衡 = FTS, 深度 =
/// semantic vectors (disabled until the vector index is built).
struct CommandPalette: View {
    @Bindable var model: AppModel
    let onClose: () -> Void

    @State private var query = ""
    @State private var mode: SearchMode = .fast
    // Computed once per (debounced) search, NOT per keystroke render — sectioning
    // over *all* matches in `body` made typing janky.
    @State private var sections: [PaletteSection] = []
    @State private var sourceByPath: [String: String] = [:]
    @State private var loading = false
    @State private var selected = 0
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

    private let perType = 5

    private var promoteType: EntryType? {
        if case .type(let t) = model.browsePane { return t } else { return nil }
    }

    private var flat: [Entry] { sections.flatMap { $0.top } }

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

            TextField(mode.placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(Typo.title3)
                .focused($fieldFocused)
                .onSubmit { openSelected() }

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
                        .font(Typo.caption)
                        .padding(.horizontal, Space.s4)
                        .padding(.vertical, Space.s2)
                        .background(mode == m ? Color.accentColor : Color.clear)
                        .foregroundStyle(modeForeground(m, disabled: disabled))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .help(disabled ? "深度检索需要先建立向量索引（构建中）" : "Tab 切换模式")
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
            placeholder("深度检索需要先建立向量索引（构建中）")
        } else if sections.isEmpty {
            placeholder(loading ? "搜索中…" : "没有匹配的条目")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(Array(sectionBases), id: \.section.id) { item in
                            sectionView(item.section, base: item.base)
                        }
                    }
                }
                .onChange(of: selected) { _, new in
                    guard flat.indices.contains(new) else { return }
                    proxy.scrollTo(flat[new].path, anchor: .center)
                }
            }
        }
    }

    /// Pair each section with the flat index of its first row (for ↑/↓ tracking).
    private var sectionBases: [(section: PaletteSection, base: Int)] {
        var out: [(PaletteSection, Int)] = []
        var n = 0
        for s in sections { out.append((s, n)); n += s.top.count }
        return out
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

    private func row(_ entry: Entry, index: Int) -> some View {
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
        }
        .padding(.horizontal, Space.s5)
        .padding(.vertical, Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSel ? Color.accentColor.opacity(0.15) : .clear)
        .contentShape(Rectangle())
        .onHover { if $0 { selected = index } }
        .onTapGesture { openPath(entry.path) }
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
            let secs = paletteSections(result.map { (entry: $0.entry, score: $0.score) },
                                       order: model.typeOrder, promote: promote, perType: perType,
                                       minimumInlineScoreRatio: currentMode.paletteInlineScoreFloorRatio)
            var src: [String: String] = [:]
            for r in result where r.source != nil { src[r.entry.path] = r.source }
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
        selected = min(max(0, selected + delta), flat.count - 1)
    }

    /// The palette always opens results in a NEW tab — it's a "find & open"
    /// action (⌘T), so it must never replace whatever the current tab is showing.
    private func openSelected() {
        guard flat.indices.contains(selected) else { return }
        openPath(flat[selected].path)
    }

    private func openPath(_ path: String) {
        onClose()
        Task { await model.openFromPalette(path, newTab: true) }
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
