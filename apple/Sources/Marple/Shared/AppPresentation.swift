import Foundation
import MarpleKit

/// Localized presentation vocabulary for the macOS shell. MarpleKit keeps its
/// stable, Chinese labels for non-UI consumers such as AI context packages.
enum AppPresentation {
    static func entryTypeLabel(_ type: EntryType) -> String {
        switch type {
        case .paper: return String(localized: "论文")
        case .book: return String(localized: "图书")
        case .author: return String(localized: "作者")
        case .topic: return String(localized: "专题")
        case .journal: return String(localized: "期刊")
        case .chapter: return String(localized: "章节")
        case .note: return String(localized: "笔记")
        case .image: return String(localized: "图片")
        case .talk: return String(localized: "讲座")
        case .transcript: return String(localized: "转写")
        case .other(let raw): return raw
        }
    }

    static func searchModeLabel(_ mode: SearchMode) -> String {
        switch mode {
        case .fast: return String(localized: "快速")
        case .balanced: return String(localized: "平衡")
        case .deep: return String(localized: "深度")
        }
    }

    static func searchPlaceholder(_ mode: SearchMode) -> String {
        switch mode {
        case .fast:
            return String(localized: "标题/作者/标签…  Tab 切换模式 · / 跳转类型 · ⏎ 打开")
        case .balanced:
            return String(localized: "标题/作者/标签/正文…  Tab 切换模式 · / 跳转类型 · ⏎ 打开")
        case .deep:
            return String(localized: "跨语言 / 概念 / 自然语言…  Tab 切换模式 · / 跳转类型 · ⏎ 打开")
        }
    }

    static func searchLoading(_ mode: SearchMode) -> String {
        switch mode {
        case .fast: return String(localized: "元数据…")
        case .balanced: return String(localized: "全文…")
        case .deep: return String(localized: "深度…（向量索引）")
        }
    }

    static func searchSourceBadge(_ source: String?) -> String? {
        guard let source, let head = source.split(separator: " ").first else { return nil }
        switch head {
        case "hybrid": return String(localized: "混合")
        case "vec": return String(localized: "向量")
        default: return nil
        }
    }

    static func citationFormatLabel(_ format: CitationFormat) -> String {
        switch format {
        case .inlineEN: return String(localized: "夹注 (英文)")
        case .inlineZH: return String(localized: "夹注 (中文)")
        case .title: return String(localized: "标题")
        case .markdown: return String(localized: "文献目录")
        }
    }

    static func filterFieldLabel(_ field: FilterField) -> String {
        switch field {
        case .type: return String(localized: "类型")
        case .rating: return String(localized: "评分")
        case .year: return String(localized: "年份")
        case .author: return String(localized: "作者")
        case .theme: return String(localized: "标签")
        case .source: return String(localized: "来源")
        case .haspdf: return String(localized: "有 PDF")
        case .added: return String(localized: "入库")
        }
    }

    static func filterMatchLabel(_ match: FilterMatch) -> String {
        switch match {
        case .all: return String(localized: "全部满足")
        case .any: return String(localized: "任一满足")
        }
    }

    static func filterOperatorLabel(_ op: FilterOp) -> String {
        switch op {
        case .gte: return "≥"
        case .lte: return "≤"
        case .eq: return "="
        case .contains: return String(localized: "包含")
        case .is_: return String(localized: "是")
        case .yes, .within: return ""
        }
    }

    static func filterClauseLabel(_ clause: FilterClause) -> String {
        if clause.field == .haspdf { return String(localized: "有 PDF") }
        if clause.field == .added {
            return String(localized: "入库近 \(clause.value) 天")
        }
        if clause.field == .type {
            return String(localized: "类型 是 \(entryTypeLabel(EntryType(rawValue: clause.value)))")
        }
        return "\(filterFieldLabel(clause.field)) \(filterOperatorLabel(clause.op)) \(clause.value)"
            .trimmingCharacters(in: .whitespaces)
    }

    static func sortFieldLabel(_ field: SortField) -> String {
        switch field {
        case .rating: return String(localized: "评分")
        case .year: return String(localized: "年份")
        case .added: return String(localized: "入库时间")
        case .updated: return String(localized: "更新时间")
        case .title: return String(localized: "标题")
        case .author: return String(localized: "作者")
        }
    }

    static func readerAIActionLabel(_ action: ReaderAIAction) -> String {
        switch action {
        case .reanalyze: return String(localized: "重新分析")
        case .format: return String(localized: "格式整理")
        case .translate: return String(localized: "制作译本")
        case .discuss: return String(localized: "对话讨论")
        }
    }

    static func aiDispatchTargetLabel(_ target: AIDispatchTarget) -> String {
        switch target {
        case .superset: return "Superset"
        case .orca: return "Orca"
        case .otty: return "Otty"
        case .terminal: return String(localized: "终端 (Terminal)")
        case .custom: return String(localized: "自定义")
        }
    }

    static func inspectorLabel(_ label: String) -> String {
        switch label {
        case "信息": return String(localized: "信息")
        case "目录": return String(localized: "目录")
        case "统计": return String(localized: "统计")
        case "笔记": return String(localized: "笔记")
        case "评分": return String(localized: "评分")
        case "字符": return String(localized: "字符")
        case "字": return String(localized: "字")
        case "段落": return String(localized: "段落")
        case "阅读时间": return String(localized: "阅读时间")
        case "本书": return String(localized: "本书")
        case "概述": return String(localized: "概述")
        case "本专题": return String(localized: "本专题")
        case "页面目录": return String(localized: "页面目录")
        case "无标题": return String(localized: "无标题")
        case "年份": return String(localized: "年份")
        case "期刊": return String(localized: "期刊")
        case "书籍": return String(localized: "书籍")
        case "出版": return String(localized: "出版")
        case "类型": return String(localized: "类型")
        case "创建": return String(localized: "创建")
        case "标注": return String(localized: "标注")
        case "名称": return String(localized: "名称")
        case "日期": return String(localized: "日期")
        case "来源": return String(localized: "来源")
        case "尺寸": return String(localized: "尺寸")
        case "大小": return String(localized: "大小")
        case "转写": return String(localized: "转写")
        case "讲座": return String(localized: "讲座")
        case "作者": return String(localized: "作者")
        case "讲者": return String(localized: "讲者")
        case "创作者": return String(localized: "创作者")
        case "标签": return String(localized: "标签")
        case "译本": return String(localized: "译本")
        case "专题": return String(localized: "专题")
        case "图书": return String(localized: "图书")
        case "论文": return String(localized: "论文")
        case "图像": return String(localized: "图像")
        case "专题成员": return String(localized: "专题成员")
        case "本刊论文": return String(localized: "本刊论文")
        case "同作者专著": return String(localized: "同作者专著")
        case "同作者论文": return String(localized: "同作者论文")
        case "同标签相似": return String(localized: "同标签相似")
        default: return label
        }
    }

    static func countedInspectorLabel(_ label: String, count: Int) -> String {
        switch label {
        case "笔记": return String(localized: "笔记 (\(count))")
        case "图书": return String(localized: "图书 (\(count))")
        case "论文": return String(localized: "论文 (\(count))")
        case "讲座": return String(localized: "讲座 (\(count))")
        case "图像": return String(localized: "图像 (\(count))")
        case "专题成员": return String(localized: "专题成员 (\(count))")
        case "本刊论文": return String(localized: "本刊论文 (\(count))")
        case "同作者专著": return String(localized: "同作者专著 (\(count))")
        case "同作者论文": return String(localized: "同作者论文 (\(count))")
        case "同标签相似": return String(localized: "同标签相似 (\(count))")
        default: return String(localized: "\(inspectorLabel(label)) (\(count))")
        }
    }

    static func readerAIDispatchErrorLabel(_ error: ReaderAIDispatchError) -> String {
        switch error {
        case .missingWorkspaceID: return String(localized: "请先在设置里填写 Superset 工作区 ID。")
        case .missingAgent: return String(localized: "请先在设置里填写代理命令。")
        case .missingCommandTemplate: return String(localized: "请先在设置里填写分发命令模板。")
        case .launchFailed: return String(localized: "无法启动分发命令，请检查设置。")
        case .failed: return String(localized: "分发命令失败，请查看日志。")
        }
    }

    static func supersetWorkspaceListErrorLabel(_ error: SupersetWorkspaceListError) -> String {
        switch error {
        case .missingCLIPath: return String(localized: "请先填写 Superset CLI 路径。")
        case .launchFailed: return String(localized: "无法启动 Superset CLI，请检查路径。")
        case .notAuthenticated: return String(localized: "Superset 未登录，请先在终端运行 superset auth login。")
        case .failed: return String(localized: "无法获取 Superset 工作区，请查看日志。")
        }
    }
}
