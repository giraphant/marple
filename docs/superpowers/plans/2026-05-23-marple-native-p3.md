# marple-native P3 Implementation Plan — Right panel + metadata write-back

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Ulysses-style right inspector (统计 / 信息 / 目录) over the reading view, with the app's first metadata writes via a surgical line-level frontmatter patch.

**Architecture:** Pure logic (stats, outline, frontmatter patch, relations) lands in `MarpleKit` under swift-testing; UI lands in `Marple` via the native `.inspector()` modifier; all I/O stays behind `VaultClient` (new `writeFile` → `PUT /vault/*path`). reader-api and the web build are untouched.

**Tech Stack:** Swift 5.9+ / SwiftUI (macOS 14+), swift-markdown, swift-testing. Spec: `docs/superpowers/specs/2026-05-23-marple-native-p3-design.md`.

**Build/test commands:**
- Build: `cd apple && swift build`
- Test: `cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks`
- Run app: `cd apple && swift run Marple > /tmp/marple-app.log 2>&1`
- Stop run: `pkill -f "debug/Marple"; pkill -f "release/reader-api"`

**Commit discipline:** only stage files authored here; leave the user's unrelated edits (`index.html`, `src/components/*`, `src-tauri/tauri.conf.json`) unstaged.

---

## Task 1: Decode `annotates` on Entry

**Files:**
- Modify: `apple/Sources/MarpleKit/Entry.swift`
- Test: `apple/Tests/MarpleKitTests/EntryDecodeTests.swift`

- [ ] **Step 1: Write the failing test** — append to `EntryDecodeTests`:

```swift
@Test func decodesAnnotates() throws {
    let json = """
    {"path":"vault/notes/n.md","type":"note","themes":[],
     "annotates":"vault/papers/p.md"}
    """.data(using: .utf8)!
    let e = try JSONDecoder().decode(Entry.self, from: json)
    #expect(e.annotates == "vault/papers/p.md")
}

@Test func annotatesAbsentIsNil() throws {
    let json = #"{"path":"vault/papers/p.md","type":"paper-analysis","themes":[]}"#
        .data(using: .utf8)!
    let e = try JSONDecoder().decode(Entry.self, from: json)
    #expect(e.annotates == nil)
}
```

- [ ] **Step 2: Run, verify fail**

Run the test command above. Expected: compile error (`annotates` not a member).

- [ ] **Step 3: Implement** — in `Entry.swift`:
  - Add stored prop: `public let annotates: String?`
  - Add `case annotates` to `CodingKeys` (raw key is already `annotates`).
  - In `init(from:)`: `annotates = (try? c.decodeIfPresent(String.self, forKey: .annotates)) ?? nil`
  - In the memberwise `init(...)`: add `annotates: String? = nil` param (place last, default nil) and `self.annotates = annotates`.

- [ ] **Step 4: Run, verify pass** (full suite still green).

- [ ] **Step 5: Commit**

```bash
git add apple/Sources/MarpleKit/Entry.swift apple/Tests/MarpleKitTests/EntryDecodeTests.swift
git commit -m "feat(native): decode annotates on Entry"
```

---

## Task 2: DocStats (port doc-stats.ts)

**Files:**
- Create: `apple/Sources/MarpleKit/DocStats.swift`
- Test: `apple/Tests/MarpleKitTests/DocStatsTests.swift`

Reference behavior (`src/doc-stats.ts`): `words` = (count of CJK ideographs) +
(count of Latin/digit runs). `chars` = full length; `charsNoSpace` strips all
whitespace; `paragraphs` = blank-line-separated non-empty chunks; `minutes` =
`words>0 ? max(1, round(words/300)) : 0`.

- [ ] **Step 1: Write failing tests**

```swift
import Testing
@testable import MarpleKit

@Suite struct DocStatsTests {
    @Test func cjkAndLatinWordCount() {
        // "技术物 X" → 3 CJK + 1 latin run = 4
        let s = computeDocStats("技术物 X")
        #expect(s.words == 4)
    }
    @Test func paragraphsSplitOnBlankLines() {
        let s = computeDocStats("a\n\nb\n\n\nc")
        #expect(s.paragraphs == 3)
    }
    @Test func charsCountAndNoSpace() {
        let s = computeDocStats("a b\nc")
        #expect(s.chars == 5)
        #expect(s.charsNoSpace == 3)
    }
    @Test func minutesAtLeastOneWhenContent() {
        #expect(computeDocStats("hello world").minutes == 1)
        #expect(computeDocStats("").minutes == 0)
    }
    @Test func minutesRoundsByThreeHundred() {
        let body = String(repeating: "字", count: 600)  // 600 CJK words
        #expect(computeDocStats(body).words == 600)
        #expect(computeDocStats(body).minutes == 2)
    }
}
```

- [ ] **Step 2: Run, verify fail** (no such symbol `computeDocStats`).

- [ ] **Step 3: Implement** `DocStats.swift`:

```swift
import Foundation

public struct DocStats: Equatable, Sendable {
    public let chars: Int
    public let charsNoSpace: Int
    public let words: Int
    public let paragraphs: Int
    public let minutes: Int
}

// CJK ideograph ranges mirrored from src/doc-stats.ts CJK_RE.
private func isCJK(_ s: Unicode.Scalar) -> Bool {
    switch s.value {
    case 0x3400...0x4DBF,   // CJK Ext A (㐀-䶿)
         0x4E00...0x9FFF,   // CJK Unified (一-鿿)
         0xF900...0xFAFF,   // CJK Compatibility (豈-﫿)
         0x3040...0x30FF:   // Hiragana+Katakana (぀-ヿ)
        return true
    default: return false
    }
}

public func countWords(_ body: String) -> Int {
    var cjk = 0
    var latinRuns = 0
    var inRun = false
    for ch in body.unicodeScalars {
        if isCJK(ch) { cjk += 1; inRun = false; continue }
        let isLatin = ("A"..."Z").contains(Character(ch)) ||
                      ("a"..."z").contains(Character(ch)) ||
                      ("0"..."9").contains(Character(ch)) ||
                      (0x00C0...0x024F).contains(ch.value)  // Latin-1 sup..Ext-B (À-ɏ)
        if isLatin { if !inRun { latinRuns += 1; inRun = true } }
        else { inRun = false }
    }
    return cjk + latinRuns
}

public func computeDocStats(_ body: String) -> DocStats {
    let chars = body.unicodeScalars.count
    let charsNoSpace = body.unicodeScalars.filter {
        !CharacterSet.whitespacesAndNewlines.contains($0)
    }.count
    let words = countWords(body)
    let minutes = words > 0 ? max(1, Int((Double(words) / 300.0).rounded())) : 0
    return DocStats(chars: chars, charsNoSpace: charsNoSpace, words: words,
                    paragraphs: countParagraphs(body), minutes: minutes)
}

// Mirror /\n\s*\n/ split: count runs of non-blank lines separated by blank lines.
private func countParagraphs(_ body: String) -> Int {
    var count = 0
    var inPara = false
    for line in body.components(separatedBy: "\n") {
        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            inPara = false
        } else if !inPara {
            count += 1; inPara = true
        }
    }
    return count
}
```

- [ ] **Step 4: Run, verify pass.**

- [ ] **Step 5: Commit**

```bash
git add apple/Sources/MarpleKit/DocStats.swift apple/Tests/MarpleKitTests/DocStatsTests.swift
git commit -m "feat(native): port CJK-aware doc stats"
```

---

## Task 3: DocOutline (headings from RenderBlocks)

**Files:**
- Create: `apple/Sources/MarpleKit/DocOutline.swift`
- Test: `apple/Tests/MarpleKitTests/DocOutlineTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import Testing
@testable import MarpleKit

@Suite struct DocOutlineTests {
    @Test func extractsHeadingsWithLevelsAndIndex() {
        let blocks = MarkdownModel.blocks(from: "# A\n\npara\n\n## B\n\n### C")
        let items = outline(from: blocks)
        #expect(items.map(\.level) == [1, 2, 3])
        #expect(items.map(\.text) == ["A", "B", "C"])
        // blockIndex points back into `blocks`
        for it in items {
            if case .heading = blocks[it.blockIndex] {} else { Issue.record("not a heading") }
        }
    }
    @Test func ignoresNonHeadingBlocks() {
        let blocks = MarkdownModel.blocks(from: "para only\n\n- a\n- b")
        #expect(outline(from: blocks).isEmpty)
    }
    @Test func headingInCodeBlockNotCounted() {
        let blocks = MarkdownModel.blocks(from: "```\n# not a heading\n```")
        #expect(outline(from: blocks).isEmpty)
    }
}
```

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement** `DocOutline.swift`:

```swift
public struct OutlineItem: Equatable, Sendable, Identifiable {
    public let blockIndex: Int
    public let level: Int
    public let text: String
    public var id: Int { blockIndex }
}

public func outline(from blocks: [RenderBlock]) -> [OutlineItem] {
    var out: [OutlineItem] = []
    for (i, block) in blocks.enumerated() {
        if case let .heading(level, tokens) = block {
            let text = tokens.map(\.plainText).joined().trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { out.append(OutlineItem(blockIndex: i, level: level, text: text)) }
        }
    }
    return out
}
```

> Check `InlineToken` in `MarkdownModel.swift`/`Wikilink.swift` for the visible-text
> accessor. If there is no `plainText` on `InlineToken`, add a small internal
> helper `tokensText(_ tokens: [InlineToken]) -> String` in this file that switches
> over the token cases (`.text(s)` → s, `.wiki(target, label)` → label ?? target,
> etc.) instead of `tokens.map(\.plainText)`.

- [ ] **Step 4: Run, verify pass.**

- [ ] **Step 5: Commit**

```bash
git add apple/Sources/MarpleKit/DocOutline.swift apple/Tests/MarpleKitTests/DocOutlineTests.swift
git commit -m "feat(native): derive outline from rendered blocks"
```

---

## Task 4: FrontmatterPatch — scalars

**Files:**
- Create: `apple/Sources/MarpleKit/FrontmatterPatch.swift`
- Test: `apple/Tests/MarpleKitTests/FrontmatterPatchTests.swift`

- [ ] **Step 1: Write failing tests (scalars)**

```swift
import Testing
@testable import MarpleKit

@Suite struct FrontmatterPatchScalarTests {
    let file = "---\ntype: paper\ntitle: 风险\nyear: 2019\n---\n\nbody line\n"

    @Test func updatesExistingScalarInPlace() {
        let out = FrontmatterPatch.setScalar(file, key: "year", value: "2020")
        #expect(out.contains("year: 2020"))
        #expect(!out.contains("year: 2019"))
        #expect(out.hasSuffix("body line\n"))   // body untouched
    }
    @Test func insertsMissingScalarBeforeClosingFence() {
        let out = FrontmatterPatch.setScalar(file, key: "rating", value: "★★★")
        #expect(out.contains("rating: ★★★"))
        // inserted inside the fence, before body
        let fmEnd = out.range(of: "\n---\n")!
        #expect(out.range(of: "rating: ★★★")!.upperBound <= fmEnd.lowerBound)
    }
    @Test func clearRemovesLine() {
        let out = FrontmatterPatch.setScalar(file, key: "year", value: nil)
        #expect(!out.contains("year:"))
        #expect(out.contains("title: 风险"))
    }
    @Test func quotesValueWithColon() {
        let out = FrontmatterPatch.setScalar(file, key: "source", value: "a: b")
        #expect(out.contains(#"source: "a: b""#))
    }
    @Test func plainValueNoQuotesForCJK() {
        let out = FrontmatterPatch.setScalar(file, key: "topic", value: "技术物")
        #expect(out.contains("topic: 技术物"))
    }
    @Test func idempotentOnSameValue() {
        let once = FrontmatterPatch.setScalar(file, key: "year", value: "2019")
        #expect(once == file)
    }
    @Test func noFrontmatterReturnsUnchanged() {
        let raw = "no fm here\n"
        #expect(FrontmatterPatch.setScalar(raw, key: "year", value: "2020") == raw)
    }
}
```

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement** `FrontmatterPatch.swift` (scalars + quoting + fence helpers):

```swift
import Foundation

public enum FrontmatterPatch {

    /// Split into (preFenceLines incl opening, fmLines, closingIndexInfo, body).
    /// Returns nil when there is no `---` frontmatter fence.
    private struct Parsed {
        var lines: [String]      // whole file split on "\n" (no trailing synth)
        var openIdx: Int         // index of opening "---"
        var closeIdx: Int        // index of closing "---"
    }

    private static func parse(_ raw: String) -> Parsed? {
        guard raw.hasPrefix("---\n") || raw.hasPrefix("---\r\n") else { return nil }
        let lines = raw.components(separatedBy: "\n")
        var close: Int?
        for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            close = i; break
        }
        guard let c = close else { return nil }
        return Parsed(lines: lines, openIdx: 0, closeIdx: c)
    }

    private static func reassemble(_ p: Parsed) -> String {
        p.lines.joined(separator: "\n")
    }

    /// Key at the start of a frontmatter line, e.g. "year: 2019" → "year".
    private static func keyOf(_ line: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let k = line[line.startIndex..<colon]
        guard !k.hasPrefix(" "), !k.hasPrefix("\t"), !k.isEmpty else { return nil }
        return String(k)
    }

    static func yamlScalar(_ value: String) -> String {
        let needsQuote =
            value.isEmpty ||
            value.contains(": ") || value.hasSuffix(":") ||
            value.contains(" #") || value.hasPrefix("#") ||
            value.first.map { " \t".contains($0) } == true ||
            value.last.map { " \t".contains($0) } == true ||
            "[]{}>|*&!%@`\"'".contains(value.first ?? "x") ||
            "-?:,".contains(value.first ?? "x") ||
            ["true","false","null","yes","no","~"].contains(value.lowercased()) ||
            Double(value) != nil
        if !needsQuote { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    public static func setScalar(_ raw: String, key: String, value: String?) -> String {
        guard var p = parse(raw) else { return raw }
        // find existing line for key within (openIdx, closeIdx)
        var found: Int?
        if p.closeIdx > p.openIdx + 1 {
            for i in (p.openIdx + 1)..<p.closeIdx where keyOf(p.lines[i]) == key {
                found = i; break
            }
        }
        switch (found, value) {
        case let (idx?, v?):                       // update in place
            p.lines[idx] = "\(key): \(yamlScalar(v))"
        case let (idx?, .none):                     // clear → remove line
            p.lines.remove(at: idx)
        case let (.none, v?):                        // insert before closing fence
            p.lines.insert("\(key): \(yamlScalar(v))", at: p.closeIdx)
        case (.none, .none):                         // nothing to do
            return raw
        }
        return reassemble(p)
    }
}
```

- [ ] **Step 4: Run, verify pass.**

- [ ] **Step 5: Commit**

```bash
git add apple/Sources/MarpleKit/FrontmatterPatch.swift apple/Tests/MarpleKitTests/FrontmatterPatchTests.swift
git commit -m "feat(native): surgical frontmatter scalar patch"
```

---

## Task 5: FrontmatterPatch — themes (flow array)

**Files:**
- Modify: `apple/Sources/MarpleKit/FrontmatterPatch.swift`
- Test: `apple/Tests/MarpleKitTests/FrontmatterPatchTests.swift`

- [ ] **Step 1: Write failing tests** (append a new suite):

```swift
@Suite struct FrontmatterPatchThemesTests {
    @Test func rewritesFlowThemes() {
        let f = "---\ntype: paper\nthemes: [a, b]\n---\nbody\n"
        let out = FrontmatterPatch.setThemes(f, ["a", "b", "c"])
        #expect(out.contains("themes: [a, b, c]"))
        #expect(!out.contains("themes: [a, b]\n"))
    }
    @Test func emptyThemesEmitsBrackets() {
        let f = "---\nthemes: [a]\n---\nbody\n"
        #expect(FrontmatterPatch.setThemes(f, []).contains("themes: []"))
    }
    @Test func fixesMalformedThemes() {
        let f = "---\ntype: note\nthemes: []()\n---\nbody\n"
        let out = FrontmatterPatch.setThemes(f, ["x"])
        #expect(out.contains("themes: [x]"))
        #expect(!out.contains("[]()"))
    }
    @Test func insertsThemesWhenAbsent() {
        let f = "---\ntype: paper\n---\nbody\n"
        #expect(FrontmatterPatch.setThemes(f, ["x"]).contains("themes: [x]"))
    }
    @Test func quotesThemeWithComma() {
        let f = "---\nthemes: []\n---\nbody\n"
        let out = FrontmatterPatch.setThemes(f, ["a, b"])
        #expect(out.contains(#"themes: ["a, b"]"#))
    }
}
```

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement** — add to `FrontmatterPatch`:

```swift
    public static func setThemes(_ raw: String, _ themes: [String]) -> String {
        guard var p = parse(raw) else { return raw }
        let rendered = themes.map(themeScalar).joined(separator: ", ")
        let line = "themes: [\(rendered)]"
        var found: Int?
        if p.closeIdx > p.openIdx + 1 {
            for i in (p.openIdx + 1)..<p.closeIdx where keyOf(p.lines[i]) == "themes" {
                found = i; break
            }
        }
        if let idx = found { p.lines[idx] = line }
        else { p.lines.insert(line, at: p.closeIdx) }
        return reassemble(p)
    }

    // Flow-array element: quote when it contains comma/bracket/colon/quote.
    private static func themeScalar(_ v: String) -> String {
        let needsQuote = v.isEmpty ||
            v.contains(",") || v.contains("[") || v.contains("]") ||
            v.contains(": ") || v.contains("\"") || v.contains("#") ||
            v.first.map { " \t".contains($0) } == true ||
            v.last.map { " \t".contains($0) } == true
        if !needsQuote { return v }
        let escaped = v.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
```

- [ ] **Step 4: Run, verify pass.**

- [ ] **Step 5: Commit**

```bash
git add apple/Sources/MarpleKit/FrontmatterPatch.swift apple/Tests/MarpleKitTests/FrontmatterPatchTests.swift
git commit -m "feat(native): surgical frontmatter themes patch"
```

---

## Task 6: RelationsIndex

**Files:**
- Create: `apple/Sources/MarpleKit/RelationsIndex.swift`
- Test: `apple/Tests/MarpleKitTests/RelationsIndexTests.swift`

Reference: `splitAuthors` in `src/wiki.ts`; backlinks `useMemo` in
`src/components/PropertyPanel.tsx` (works / siblings / similar≥2-themes-cap-6 /
annotations / authorProfile). All lists sort by `ratingScore` desc.

- [ ] **Step 1: Inspect** `src/wiki.ts` `splitAuthors` to mirror its splitting rule
  (split on `;`, `,`, ` and `, ` & `, Chinese `、`; trim; drop empties). Note the
  exact separators it uses before writing the port.

- [ ] **Step 2: Write failing tests**

```swift
import Testing
@testable import MarpleKit

@Suite struct RelationsIndexTests {
    func mk(_ path: String, _ type: String, title: String? = nil, author: String? = nil,
            themes: [String] = [], rating: Double = 0, annotates: String? = nil) -> Entry {
        Entry(path: path, type: EntryType(rawValue: type), title: title, author: author,
              year: nil, ratingScore: rating, themes: themes, preview: "", hasPDF: false,
              annotates: annotates)
    }

    @Test func splitAuthorsBasics() {
        #expect(splitAuthors("A, B") == ["A", "B"])
        #expect(splitAuthors("A and B") == ["A", "B"])
        #expect(splitAuthors(nil) == [])
    }

    @Test func annotationsByTarget() {
        let p = mk("vault/papers/p.md", "paper-analysis")
        let n = mk("vault/notes/n.md", "note", annotates: "vault/papers/p.md")
        let entries = [p, n]
        let ai = buildAnnotationIndex(entries)
        let rel = relations(for: p, in: entries, authorIndex: buildAuthorIndex(entries), annotationIndex: ai)
        #expect(rel.annotations.map(\.path) == ["vault/notes/n.md"])
    }

    @Test func siblingsAndAuthorProfile() {
        let prof = mk("vault/authors/x.md", "author-profile", title: "Jane Doe")
        let p1 = mk("vault/papers/a.md", "paper-analysis", author: "Jane Doe", rating: 1)
        let p2 = mk("vault/papers/b.md", "paper-analysis", author: "Jane Doe", rating: 3)
        let entries = [prof, p1, p2]
        let rel = relations(for: p1, in: entries,
                            authorIndex: buildAuthorIndex(entries),
                            annotationIndex: buildAnnotationIndex(entries))
        #expect(rel.authorProfile?.path == "vault/authors/x.md")
        #expect(rel.siblings.map(\.path) == ["vault/papers/b.md"])   // not self, rating desc
    }

    @Test func similarSharesTwoThemes() {
        let base = mk("vault/papers/a.md", "paper-analysis", themes: ["t1","t2","t3"])
        let sim  = mk("vault/papers/b.md", "paper-analysis", themes: ["t1","t2"], rating: 2)
        let no   = mk("vault/papers/c.md", "paper-analysis", themes: ["t1"])
        let entries = [base, sim, no]
        let rel = relations(for: base, in: entries,
                            authorIndex: buildAuthorIndex(entries),
                            annotationIndex: buildAnnotationIndex(entries))
        #expect(rel.similar.map(\.path) == ["vault/papers/b.md"])
    }

    @Test func worksForAuthorProfile() {
        let prof = mk("vault/authors/x.md", "author-profile", title: "Jane Doe")
        let p1 = mk("vault/papers/a.md", "paper-analysis", author: "Jane Doe", rating: 5)
        let entries = [prof, p1]
        let rel = relations(for: prof, in: entries,
                            authorIndex: buildAuthorIndex(entries),
                            annotationIndex: buildAnnotationIndex(entries))
        #expect(rel.works.map(\.path) == ["vault/papers/a.md"])
    }
}
```

- [ ] **Step 3: Run, verify fail.**

- [ ] **Step 4: Implement** `RelationsIndex.swift`:

```swift
import Foundation

public func splitAuthors(_ s: String?) -> [String] {
    guard let s, !s.isEmpty else { return [] }
    // Mirror src/wiki.ts: separators ; , 、 and " and ".
    let normalized = s.replacingOccurrences(of: " and ", with: ",")
                      .replacingOccurrences(of: ";", with: ",")
                      .replacingOccurrences(of: "、", with: ",")
    return normalized.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

public func buildAuthorIndex(_ entries: [Entry]) -> [String: [Entry]] {
    var idx: [String: [Entry]] = [:]
    for e in entries {
        for name in splitAuthors(e.author) {
            idx[name.lowercased(), default: []].append(e)
        }
    }
    return idx
}

public func buildAnnotationIndex(_ entries: [Entry]) -> [String: [Entry]] {
    var idx: [String: [Entry]] = [:]
    for e in entries where e.type == .note {
        if let target = e.annotates, !target.isEmpty {
            idx[target, default: []].append(e)
        }
    }
    return idx
}

public struct Relations: Equatable, Sendable {
    public var works: [Entry] = []
    public var siblings: [Entry] = []
    public var similar: [Entry] = []
    public var annotations: [Entry] = []
    public var authorProfile: Entry?
}

private func byRatingDesc(_ a: Entry, _ b: Entry) -> Bool { a.ratingScore > b.ratingScore }

public func relations(for entry: Entry, in entries: [Entry],
                      authorIndex: [String: [Entry]],
                      annotationIndex: [String: [Entry]]) -> Relations {
    var out = Relations()
    out.annotations = (annotationIndex[entry.path] ?? []).sorted(by: byRatingDesc)

    if entry.type == .authorProfile {
        let key = (entry.title ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        out.works = key.isEmpty ? [] : (authorIndex[key] ?? [])
            .filter { $0.path != entry.path }
            .sorted(by: byRatingDesc)
    }

    if entry.type == .paperAnalysis || entry.type == .bookOverview {
        var siblings: [Entry] = []
        var seen = Set<String>()
        for name in splitAuthors(entry.author) {
            let key = name.lowercased()
            if out.authorProfile == nil {
                out.authorProfile = entries.first {
                    $0.type == .authorProfile && ($0.title ?? "").lowercased() == key
                }
            }
            for w in authorIndex[key] ?? [] where w.path != entry.path && !seen.contains(w.path) {
                seen.insert(w.path); siblings.append(w)
            }
        }
        out.siblings = siblings.sorted(by: byRatingDesc)

        let own = Set(entry.themes)
        if own.count >= 2 {
            var scored: [(Int, Entry)] = []
            for e in entries where e.path != entry.path && e.type == entry.type {
                let n = e.themes.filter { own.contains($0) }.count
                if n >= 2 { scored.append((n, e)) }
            }
            scored.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1.ratingScore > $1.1.ratingScore }
            out.similar = scored.prefix(6).map(\.1)
        }
    }
    return out
}
```

> If `splitAuthors` in `src/wiki.ts` uses different separators than assumed,
> adjust the `normalized` replacements to match exactly before committing.

- [ ] **Step 5: Run, verify pass.**

- [ ] **Step 6: Commit**

```bash
git add apple/Sources/MarpleKit/RelationsIndex.swift apple/Tests/MarpleKitTests/RelationsIndexTests.swift
git commit -m "feat(native): port author/annotation relations index"
```

---

## Task 7: VaultClient.writeFile (PUT)

**Files:**
- Modify: `apple/Sources/MarpleKit/VaultClient.swift` (protocol + Stub)
- Modify: `apple/Sources/MarpleKit/HTTPVaultClient.swift`
- Test: `apple/Tests/MarpleKitTests/HTTPVaultClientTests.swift`

- [ ] **Step 1: Write failing test** — follow the existing `URLProtocol` mock
  pattern already used in `HTTPVaultClientTests.swift` (inspect it first for the
  helper name). Assert method/url/body:

```swift
@Test func writeFilePutsFullText() async throws {
    MockURLProtocol.handler = { req in
        #expect(req.httpMethod == "PUT")
        #expect(req.url!.absoluteString == "http://localhost:9/vault/notes/n.md")
        let body = req.httpBodyStreamData() ?? req.httpBody ?? Data()
        #expect(String(decoding: body, as: UTF8.self) == "new text")
        return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
    }
    let client = HTTPVaultClient(baseURL: URL(string: "http://localhost:9")!, session: mockSession())
    try await client.writeFile(path: "vault/notes/n.md", text: "new text")
}
```

> Match `MockURLProtocol`/`mockSession()`/`httpBodyStreamData` to whatever the
> existing tests define. If the existing tests read the body differently, reuse
> that exact mechanism (URLProtocol strips `httpBody` into a stream).

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement**
  - In `VaultClient.swift` protocol add: `func writeFile(path: String, text: String) async throws`
  - In `StubVaultClient` add a recorded write. Since the struct is `Sendable` and
    methods aren't mutating across actors, store via a class box:

```swift
public final class WriteLog: @unchecked Sendable {
    public private(set) var last: (path: String, text: String)?
    public init() {}
    public func record(_ p: String, _ t: String) { last = (p, t) }
}
// add `public let writeLog = WriteLog()` to StubVaultClient and:
public func writeFile(path: String, text: String) async throws { writeLog.record(path, text) }
```

  - In `HTTPVaultClient.swift`:

```swift
public func writeFile(path: String, text: String) async throws {
    var req = URLRequest(url: URL(string: baseURL.absoluteString + "/" + path)!)
    req.httpMethod = "PUT"
    req.setValue("text/markdown; charset=utf-8", forHTTPHeaderField: "Content-Type")
    req.httpBody = Data(text.utf8)
    _ = try await run(req)
}
```

- [ ] **Step 4: Run, verify pass** (all suites; Stub change compiles existing tests).

- [ ] **Step 5: Commit**

```bash
git add apple/Sources/MarpleKit/VaultClient.swift apple/Sources/MarpleKit/HTTPVaultClient.swift apple/Tests/MarpleKitTests/HTTPVaultClientTests.swift
git commit -m "feat(native): VaultClient.writeFile via PUT /vault"
```

---

## Task 8: AppModel — derived caches + write intents

**Files:**
- Modify: `apple/Sources/Marple/AppModel.swift`

No unit test (UI/state layer; validated by build + manual GUI). Keep all
recomputation off the render path (P2 discipline).

- [ ] **Step 1: Add state**
  - `private(set) var openEntry: Entry?`
  - `private(set) var openBody: String = ""`
  - `private(set) var openOutline: [OutlineItem] = []`
  - `private(set) var openStats: DocStats?`
  - `private(set) var openRelations: Relations?`
  - `private(set) var authorIndex: [String: [Entry]] = [:]`
  - `private(set) var annotationIndex: [String: [Entry]] = [:]`
  - `var scrollTarget: Int?`
  - `private(set) var savingField: String?`
  - `var writeError: String?`

- [ ] **Step 2: Build indexes** — in `rebuildIndexDerived()` append:

```swift
authorIndex = buildAuthorIndex(entries)
annotationIndex = buildAnnotationIndex(entries)
```

- [ ] **Step 3: Compute open-doc caches** — refactor `open(_:)` so after blocks are
  built it also sets body + caches:

```swift
func open(_ path: String) async {
    openPath = path
    do {
        let raw = try await client.entryText(path: path)
        let split = Frontmatter.split(raw)
        openBody = split.body
        openBlocks = MarkdownModel.blocks(from: split.body)
        recomputeOpenDerived()
        print("[marple] open \(path) -> \(openBlocks.count) blocks (\(raw.count) chars)")
    } catch {
        openBlocks = [.paragraph([.text("load failed: \(error)")])]
        openBody = ""; recomputeOpenDerived()
        print("[marple] open FAILED \(path): \(error)")
    }
}

private func recomputeOpenDerived() {
    openEntry = entries.first { $0.path == openPath }
    openOutline = outline(from: openBlocks)
    openStats = openBody.isEmpty ? nil : computeDocStats(openBody)
    if let e = openEntry {
        openRelations = relations(for: e, in: entries,
                                  authorIndex: authorIndex, annotationIndex: annotationIndex)
    } else { openRelations = nil }
}
```

- [ ] **Step 4: Write intents** — add a private helper + public intents:

```swift
private func applyPatch(field: String, _ patch: @escaping (String) -> String,
                        local: @escaping (Entry) -> Entry) async {
    guard let path = openPath else { return }
    savingField = field; writeError = nil
    defer { savingField = nil }
    do {
        let fresh = try await client.entryText(path: path)
        let next = patch(fresh)
        try await client.writeFile(path: path, text: next)
        if let i = entries.firstIndex(where: { $0.path == path }) {
            entries[i] = local(entries[i])
        }
        rebuildIndexDerived()        // themes/rating affect themeIndex/filters/counts
        recomputeVisible()
        recomputeOpenDerived()
        print("[marple] wrote \(field) -> \(path)")
    } catch {
        writeError = "\(error)"
        print("[marple] write FAILED \(field) \(path): \(error)")
    }
}

func setRating(_ stars: Int?) async {
    let value = (stars ?? 0) > 0 ? String(repeating: "★", count: min(5, max(1, stars!))) : nil
    await applyPatch(field: "rating",
        { FrontmatterPatch.setScalar($0, key: "rating", value: value) },
        { $0.with(ratingScore: Double(stars ?? 0)) })
}
func setYear(_ text: String?) async {
    let v = text?.trimmingCharacters(in: .whitespaces); let val = (v?.isEmpty ?? true) ? nil : v
    await applyPatch(field: "year",
        { FrontmatterPatch.setScalar($0, key: "year", value: val) },
        { $0.with(year: val) })
}
func setSource(_ text: String?) async {
    let v = text?.trimmingCharacters(in: .whitespaces); let val = (v?.isEmpty ?? true) ? nil : v
    await applyPatch(field: "source",
        { FrontmatterPatch.setScalar($0, key: "source", value: val) },
        { $0.with(source: val) })
}
func setTopic(_ text: String?) async {
    let v = text?.trimmingCharacters(in: .whitespaces); let val = (v?.isEmpty ?? true) ? nil : v
    await applyPatch(field: "topic",
        { FrontmatterPatch.setScalar($0, key: "topic", value: val) },
        { $0.with(topic: val) })
}
func setDoi(_ text: String?) async {
    let v = text?.trimmingCharacters(in: .whitespaces); let val = (v?.isEmpty ?? true) ? nil : v
    await applyPatch(field: "doi",
        { FrontmatterPatch.setScalar($0, key: "doi", value: val) },
        { $0.with(doi: val) })
}
func addThemes(_ raw: String) async {
    let add = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard !add.isEmpty, let cur = openEntry?.themes else { return }
    var next = cur; for t in add where !next.contains(t) { next.append(t) }
    await applyPatch(field: "themes",
        { FrontmatterPatch.setThemes($0, next) },
        { $0.with(themes: next) })
}
func removeTheme(_ theme: String) async {
    guard let cur = openEntry?.themes else { return }
    let next = cur.filter { $0 != theme }
    await applyPatch(field: "themes",
        { FrontmatterPatch.setThemes($0, next) },
        { $0.with(themes: next) })
}
```

- [ ] **Step 5: Add `Entry.with(...)` copy helper** — in `Entry.swift`, an extension
  returning a copy with selected fields replaced (path/type/title/author/preview/
  hasPDF unchanged unless passed). Implement only the fields used above
  (ratingScore, year, source, topic, doi, themes):

```swift
public extension Entry {
    func with(ratingScore: Double? = nil, year: String?? = nil, source: String?? = nil,
              topic: String?? = nil, doi: String?? = nil, themes: [String]? = nil) -> Entry {
        Entry(path: path, type: type, title: title, author: author,
              year: year ?? self.year, ratingScore: ratingScore ?? self.ratingScore,
              themes: themes ?? self.themes, preview: preview, hasPDF: hasPDF,
              mtime: mtime, added: added, source: source ?? self.source,
              book: book, topic: topic ?? self.topic, doi: doi ?? self.doi,
              annotates: annotates)
    }
}
```

> Note the double-optional (`String??`) so callers can pass `nil` to clear vs omit
> to keep. `year ?? self.year` collapses correctly: passing `.some(nil)` clears.

- [ ] **Step 6: Build** `cd apple && swift build`. Expected: clean. Fix signature
  mismatches against earlier tasks if any.

- [ ] **Step 7: Commit**

```bash
git add apple/Sources/Marple/AppModel.swift apple/Sources/MarpleKit/Entry.swift
git commit -m "feat(native): AppModel open-doc caches + metadata write intents"
```

---

## Task 9: InspectorView

**Files:**
- Create: `apple/Sources/Marple/InspectorView.swift`

No unit test (SwiftUI view). Validated by build + GUI.

- [ ] **Step 1: Implement the panel** — a `ScrollViewReader { ScrollView { VStack … } }`
  with three anchored sections and a top icon strip. Structure:

```swift
import SwiftUI
import MarpleKit

struct InspectorView: View {
    @Bindable var model: AppModel
    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 18) {
                    Button { withAnimation { proxy.scrollTo("stats", anchor: .top) } } label: { Image(systemName: "chart.bar") }
                    Button { withAnimation { proxy.scrollTo("info", anchor: .top) } } label: { Image(systemName: "list.bullet.rectangle") }
                    Button { withAnimation { proxy.scrollTo("outline", anchor: .top) } } label: { Image(systemName: "list.number") }
                }
                .buttonStyle(.plain).padding(.vertical, 8)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        StatsSection(stats: model.openStats).id("stats")
                        InfoSection(model: model).id("info")
                        OutlineSection(model: model).id("outline")
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
```

- [ ] **Step 2: StatsSection**

```swift
private struct StatsSection: View {
    let stats: DocStats?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("统计")
            if let s = stats {
                StatRow("字符", "\(s.chars)")
                StatRow("字", "\(s.words)")
                StatRow("段落", "\(s.paragraphs)")
                StatRow("阅读时间", s.minutes > 0 ? "\(s.minutes) 分钟" : "—")
            } else { Text("—").foregroundStyle(.secondary) }
        }
    }
}
private struct StatRow: View {
    let label: String; let value: String
    init(_ l: String, _ v: String) { label = l; value = v }
    var body: some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).monospacedDigit() }
            .font(.callout)
    }
}
private struct SectionHeader: View {
    let title: String; init(_ t: String) { title = t }
    var body: some View {
        Text(title).font(.caption).fontWeight(.semibold)
            .foregroundStyle(.secondary).textCase(.uppercase)
    }
}
```

- [ ] **Step 3: OutlineSection** (click → scrollTarget)

```swift
private struct OutlineSection: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader("目录")
            if model.openOutline.isEmpty {
                Text("无标题").foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(model.openOutline) { item in
                    Button { model.scrollTarget = item.blockIndex } label: {
                        Text(item.text).font(.callout).lineLimit(1)
                            .padding(.leading, CGFloat((item.level - 1) * 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
```

- [ ] **Step 4: InfoSection** (editable rows + relations) — editable per
  `FIELDS_BY_TYPE` in `PropertyPanel.tsx`. Rating uses a 5-button ★ picker; scalar
  rows use a TextField that commits on submit; themes are chips with a remove
  button + an add field; author is read-only with a profile-link button. Relations
  render as tappable rows that call `model.open`.

```swift
private struct InfoSection: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("信息")
            if let err = model.writeError {
                Text("保存失败：\(err)").font(.caption).foregroundStyle(.red)
            }
            if let e = model.openEntry {
                let fields = editableFields(for: e.type)
                Group {
                    if fields.contains("rating") { RatingRow(model: model, score: Int(e.ratingScore)) }
                    if fields.contains("year")   { ScalarRow(model: model, label: "年份", value: e.year, commit: { await model.setYear($0) }) }
                    if e.author?.isEmpty == false { AuthorRow(model: model, entry: e) }
                    if fields.contains("source") { ScalarRow(model: model, label: "来源", value: e.source, commit: { await model.setSource($0) }) }
                    if fields.contains("doi")    { ScalarRow(model: model, label: "DOI", value: e.doi, commit: { await model.setDoi($0) }) }
                    if fields.contains("topic")  { ScalarRow(model: model, label: "专题", value: e.topic, commit: { await model.setTopic($0) }) }
                }
                .disabled(model.savingField != nil)
                ThemesEditor(model: model, themes: e.themes)
                RelationsView(model: model)
            } else { Text("—").foregroundStyle(.secondary) }
        }
    }
}

// Mirror FIELDS_BY_TYPE (PropertyPanel.tsx); themes handled separately.
func editableFields(for type: EntryType) -> Set<String> {
    switch type {
    case .paperAnalysis:  return ["rating","year","source","doi","topic"]
    case .bookOverview:   return ["rating","year","source","topic"]
    case .chapterSummary: return ["rating","year","source","topic"]
    case .authorProfile:  return ["rating"]
    case .topicSynthesis: return ["rating","topic"]
    case .note:           return []
    case .other:          return []
    }
}
```

- [ ] **Step 5: Row components** — `RatingRow`, `ScalarRow`, `AuthorRow`,
  `ThemesEditor`, `RelationsView`, `RelRow`:

```swift
private struct RatingRow: View {
    @Bindable var model: AppModel; let score: Int
    var body: some View {
        HStack {
            Text("评分").foregroundStyle(.secondary)
            Spacer()
            ForEach(1...5, id: \.self) { n in
                Button { Task { await model.setRating(n == score ? nil : n) } } label: {
                    Image(systemName: n <= score ? "star.fill" : "star")
                }.buttonStyle(.plain).foregroundStyle(.yellow)
            }
        }.font(.callout)
    }
}

private struct ScalarRow: View {
    @Bindable var model: AppModel
    let label: String; let value: String?
    let commit: (String) async -> Void
    @State private var draft = ""
    @State private var editing = false
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            if editing {
                TextField(label, text: $draft)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                    .onSubmit { Task { await commit(draft); editing = false } }
            } else {
                Button { draft = value ?? ""; editing = true } label: {
                    Text(value?.isEmpty == false ? value! : "—")
                        .foregroundStyle(value?.isEmpty == false ? .primary : .secondary)
                }.buttonStyle(.plain)
            }
        }.font(.callout)
    }
}

private struct AuthorRow: View {
    @Bindable var model: AppModel; let entry: Entry
    var body: some View {
        HStack {
            Text("作者").foregroundStyle(.secondary)
            Spacer()
            if let prof = model.openRelations?.authorProfile {
                Button { Task { await model.open(prof.path) } } label: {
                    Text(entry.author ?? "").lineLimit(1)
                }.buttonStyle(.link)
            } else {
                Text(entry.author ?? "").lineLimit(1)
            }
        }.font(.callout)
    }
}

private struct ThemesEditor: View {
    @Bindable var model: AppModel; let themes: [String]
    @State private var adding = false
    @State private var draft = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionHeader("主题"); Spacer()
                Button(adding ? "取消" : "+ 添加") { adding.toggle() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
            FlowChips(themes: themes, onRemove: { t in Task { await model.removeTheme(t) } },
                      onTap: { t in model.select(pane: .theme(t)) })
            if adding {
                TextField("新主题（逗号分隔可多个）", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.addThemes(draft); draft = ""; adding = false } }
            }
        }.disabled(model.savingField != nil)
    }
}

private struct FlowChips: View {
    let themes: [String]; let onRemove: (String) -> Void; let onTap: (String) -> Void
    var body: some View {
        if themes.isEmpty { Text("—").foregroundStyle(.secondary).font(.callout) }
        else {
            // Simple wrapping via a vertical list of horizontal chips is acceptable
            // for P3; a true flow layout can come later. Use a basic HStack-wrap.
            WrapHStack(themes) { t in
                HStack(spacing: 2) {
                    Button(t) { onTap(t) }.buttonStyle(.plain)
                    Button { onRemove(t) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
            }
        }
    }
}

private struct RelationsView: View {
    @Bindable var model: AppModel
    var body: some View {
        if let r = model.openRelations {
            VStack(alignment: .leading, spacing: 12) {
                relGroup("作者作品", r.works)
                relGroup("同作者", r.siblings)
                relGroup("同主题相似", r.similar)
                relGroup("我的批注", r.annotations)
            }
        }
    }
    @ViewBuilder private func relGroup(_ title: String, _ list: [Entry]) -> some View {
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                SectionHeader("\(title) (\(list.count))")
                ForEach(list.prefix(30)) { e in
                    Button { Task { await model.open(e.path) } } label: {
                        Text(e.title ?? e.path).font(.callout).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}
```

> `WrapHStack` is not a stdlib type. Implement a minimal wrapping container in this
> file (using `Layout` protocol, macOS 13+) OR, to keep P3 simple, replace
> `FlowChips`'s `WrapHStack(themes){}` with a plain `VStack`/`LazyVGrid(columns:
> [GridItem(.adaptive(minimum: 80))])` of chips. Pick the grid to avoid writing a
> custom Layout. Update `FlowChips` accordingly.

- [ ] **Step 6: Build** `cd apple && swift build`. Fix any API mismatches
  (e.g. `Pane.theme` case name — confirm against `Browse.swift`).

- [ ] **Step 7: Commit**

```bash
git add apple/Sources/Marple/InspectorView.swift
git commit -m "feat(native): Ulysses-style inspector (stats/info/outline)"
```

---

## Task 10: DocView — ScrollViewReader + .inspector + scroll coordination

**Files:**
- Modify: `apple/Sources/Marple/DocView.swift`

- [ ] **Step 1: Add inspector state + wrap content**

```swift
struct DocView: View {
    @Bindable var model: AppModel
    @State private var inspectorShown = true
    var body: some View {
        Group {
            if model.openPath == nil {
                ContentUnavailableView("选择一篇文档", systemImage: "doc.text")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(model.openBlocks.enumerated()), id: \.offset) { idx, block in
                                BlockView(block: block).id(idx)
                            }
                        }
                        .frame(maxWidth: 720, alignment: .leading)
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .onChange(of: model.scrollTarget) { _, target in
                        if let t = target {
                            withAnimation { proxy.scrollTo(t, anchor: .top) }
                            model.scrollTarget = nil
                        }
                    }
                    .environment(\.openURL, OpenURLAction { url in
                        if let target = WikiURL.target(from: url) {
                            Task { await model.follow(target) }
                            return .handled
                        }
                        return .systemAction
                    })
                }
            }
        }
        .inspector(isPresented: $inspectorShown) {
            InspectorView(model: model)
                .inspectorColumnWidth(min: 240, ideal: 300, max: 420)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("用外部编辑器打开") { Task { await model.openExternally() } }
                    .disabled(model.openPath == nil)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { inspectorShown.toggle() } label: { Image(systemName: "sidebar.trailing") }
            }
        }
    }
}
```

> `onChange(of:)` two-param closure requires macOS 14. Confirm the deployment
> target in `Package.swift` is `.macOS(.v14)`; if it is `.v13`, either bump it
> (preferred, `.inspector` also needs v14) or use the single-param `onChange`.

- [ ] **Step 2: Verify Package.swift platform** — open `apple/Package.swift`; ensure
  `platforms: [.macOS(.v14)]`. If lower, bump to `.v14` (required by `.inspector`
  and 2-param `onChange`). This is the only place to change it.

- [ ] **Step 3: Build** `cd apple && swift build`. Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add apple/Sources/Marple/DocView.swift apple/Package.swift
git commit -m "feat(native): inspector panel + outline scroll in DocView"
```

---

## Task 11: Full build, test, manual GUI checklist

- [ ] **Step 1: Full test suite**

Run: `cd apple && swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks`
Expected: all suites pass (P1/P2's 50 + new DocStats/DocOutline/FrontmatterPatch/
RelationsIndex/Entry-annotates/writeFile tests).

- [ ] **Step 2: Build + run on the real vault**

Run: `cd apple && swift run Marple > /tmp/marple-app.log 2>&1` (background), then
tail the log. Expect `[marple] index loaded: …`.

- [ ] **Step 3: Manual GUI checklist** (hand to the user)
  - Inspector toggles via the toolbar button; defaults visible with a doc open.
  - Icon strip jumps to 统计 / 信息 / 目录.
  - 统计 shows 字符/字/段落/阅读时间 for the open doc.
  - 目录 lists headings; clicking one scrolls the reading view to it.
  - 信息: edit 评分 (★), 年份, 专题 etc., add/remove a 主题 → on-disk frontmatter
    changes; `git diff <file>` shows a single clean changed line; sidebar
    rating/theme filters reflect the change.
  - 关系: 同作者 / 同主题相似 / 我的批注 / 作者档案 link and navigate.
  - Regression: wikilinks still navigate, 用外部编辑器打开 works, type switching is
    still fast (P1/P2).

- [ ] **Step 4: Stop the run**

Run: `pkill -f "debug/Marple"; pkill -f "release/reader-api"`

- [ ] **Step 5: Write the P3 handoff doc** at
  `docs/superpowers/2026-05-23-marple-native-p3-handoff.md` (mirror the P2 handoff:
  what shipped, architecture, verification, GUI checklist, deferred items) and
  commit.
