import SwiftUI
import MarpleKit

struct DocScreen: View {
    @Bindable var model: ReaderModel
    let entry: Entry
    @State private var rendered = NSAttributedString()
    @State private var stats: DocStats?
    @State private var outline: [OutlineItem] = []
    @State private var showInspector = false

    private var style: RenderStyle {
        RenderStyle(size: 18, fontFamily: nil, bodyWeight: .regular,
                    letterSpacing: 0, lineHeight: 1.6)
    }

    var body: some View {
        MarkdownTextView(attributed: rendered)
            .navigationTitle(entry.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button { showInspector = true } label: { Image(systemName: "info.circle") }
            }
            .sheet(isPresented: $showInspector) {
                InspectorSheet(entry: entry, stats: stats, outline: outline)
            }
            .task(id: entry.id) { await load() }
    }

    private func load() async {
        let raw = await model.text(for: entry)
        let md = Wikilink.preprocessForRendering(raw)
        let doc = MarkdownRenderer.render(md, style: style)
        rendered = doc.attributedString
        outline = MarpleKit.outline(from: doc.headings)
        stats = computeDocStats(raw)
    }
}

private struct InspectorSheet: View {
    let entry: Entry
    let stats: DocStats?
    let outline: [OutlineItem]

    var body: some View {
        NavigationStack {
            List {
                if let s = stats {
                    Section("统计") {
                        LabeledContent("字数", value: "\(s.chars)")
                        LabeledContent("词数", value: "\(s.words)")
                        LabeledContent("段落", value: "\(s.paragraphs)")
                        LabeledContent("阅读", value: "\(s.minutes) 分钟")
                    }
                }
                Section("信息") {
                    LabeledContent("类型", value: entry.type.label)
                    if !entry.author.isEmpty { LabeledContent("作者", value: entry.author.joined(separator: ", ")) }
                    if let y = entry.year { LabeledContent("年份", value: y) }
                    if !entry.themes.isEmpty { LabeledContent("主题", value: entry.themes.joined(separator: " · ")) }
                }
                if !outline.isEmpty {
                    Section("目录") {
                        ForEach(outline) { item in
                            Text(item.text)
                                .font(.callout)
                                .padding(.leading, CGFloat((item.level - 1) * 12))
                        }
                    }
                }
            }
            .navigationTitle("信息")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
