import Foundation

enum ReaderAIPrompts {
    static let reanalyze = """
    当前目标文件的分析质量需要重新处理。请先阅读上下文包，再按 Quasi 既有能力判断路线：paper / chapter 类分析文件优先使用 analyse-agent 的规范重新分析；book overview、author profile、topic synthesis 或其他综合型页面优先使用 synthesis-agent 的相应规范重新综合。

    如果上下文显示这是 book / chapter 体系，且章节缺失、章节分析不全、章节标题/slot 明显不完整，或当前 overview 依赖尚未补齐的章节，不要只重写当前 overview。请按 quasi:process-book 的工作流语义处理：先补齐缺失章节分析（一章一个 analyse-agent），再由 synthesis-agent(mode=book) 重新生成整本书综合。可以重写目标文件，但不要创建与当前任务无关的文件；保留并修正符合 Quasi schema 的 frontmatter；不要编造不存在的文献、DOI、页码、引文或事实。
    """

    static let formatAudit = """
    当前目标文件只需要做 Quasi audit 语义下的规范检查与格式整理。必须调用 Quasi audit 能力处理目标文件：优先使用 quasi:audit-agent；或执行 quasi-audit --path {{target_relative_path}}。

    quasi-audit 是唯一入口。只处理 diagnostics 明确允许的局部最小修复，包括 frontmatter/schema、标题层级、必需小节、metadata、机械格式问题，以及章节标题语言不一致这类 schema/consistency 问题。保留原事实和原措辞。不要重新分析正文，不要扩写观点，不要新增无依据内容，不要补写不存在的实质段落，不要写入 cache，不要写 manifest，不要维护跨文件状态。如果 audit 能力不可用，请说明失败原因，不要自行发挥修复。
    """

    static let translatePDF = """
    请为当前阅读对象制作 PDF 译本。先阅读上下文包中的 Source Paths，找到当前对象对应的 sources/{slug}.pdf；调用 quasi:translate-agent 或 quasi-translate 处理已有 PDF，目标产物是 processing/translations/{slug}-zh.pdf。

    这是 PDF-only 动作。不要翻译或改写当前 markdown 文件。若上下文里没有可用 source PDF，请说明无法制作译本以及缺少的 source slug / PDF 路径。
    """

    static let discuss = """
    请把上下文包当作当前阅读对象的背景材料，和我展开对话讨论。你应保持客观、中立、批判性的思考姿态：帮助我澄清概念、追问论证前提、指出可能的反例或薄弱处，也可以提出可继续阅读的问题。

    这个动作只是为了省去手动复制书名、章节、作者、相关条目和 source 路径。不要编辑任何文件，不要创建笔记，不要整理格式，不要重新分析或综合正文。
    """

    static let reanalysisBoundary = "请先阅读上下文包。默认优先编辑目标文件；如果重新分析需要补全同一本书，请允许创建或更新同一本书目录内缺失的章节分析文件与 00-overview.md。不要因为默认目标文件边界而跳过必要的章节补全；不要编辑上下文包或无关文件。"
    static let targetEditBoundary = "请先阅读上下文包。只编辑目标文件，不要编辑上下文包或其他文件。"
    static let discussionBoundary = "请先阅读上下文包。本动作只用于对话讨论，不要编辑、创建或删除任何文件。"

    static let contextReanalysisBoundary = "Default to editing the target file above. If reanalysis requires completing the same book, edits may include same-book overview/chapter analysis files only. Do not edit this context package."
    static let contextTargetEditBoundary = "Only edit the target file above. Do not edit this context package."
    static let contextDiscussionBoundary = "Do not edit, create, or delete files for this discussion action. Do not edit this context package."

    static let auditGuardrail = """
    不可覆盖的格式整理约束：必须调用 quasi:audit-agent 或 quasi-audit --path {{target_relative_path}}；quasi-audit 是唯一入口。只做 diagnostics 允许的本地最小修改。保留原事实和原措辞；不要重新分析、扩写、补写实质内容、编造内容、写 cache、写 manifest 或维护跨文件状态。
    """
}
