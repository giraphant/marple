import Foundation
import MarpleKit

#if DEBUG && targetEnvironment(simulator)
enum DemoVaultWorkspace {
    static let launchArgument = "-MarpleDemoVault"
    static let readerLaunchArgument = "-MarpleDemoReader"
    static let menuLaunchArgument = "-MarpleDemoMenu"
    static let environmentKey = "MARPLE_DEMO_VAULT"
    static let readerEnvironmentKey = "MARPLE_DEMO_READER"
    static let menuEnvironmentKey = "MARPLE_DEMO_MENU"
    static let readerPathEnvironmentKey = "MARPLE_DEMO_READER_PATH"
    static let defaultReaderPath = "vault/topics/repair-morphology-interface-control/00-overview.md"

    enum ReaderOverlay: String {
        case outline
        case contents
        case info
        case font
    }

    static var isEnabled: Bool {
        let env = ProcessInfo.processInfo.environment[environmentKey]?.lowercased()
        return ProcessInfo.processInfo.arguments.contains(launchArgument)
            || env == "1"
            || env == "true"
            || env == "yes"
    }

    static var shouldOpenReader: Bool {
        let env = ProcessInfo.processInfo.environment[readerEnvironmentKey]?.lowercased()
        return ProcessInfo.processInfo.arguments.contains(readerLaunchArgument)
            || env == "1"
            || env == "true"
            || env == "yes"
    }

    static var shouldOpenReaderMenu: Bool {
        let env = ProcessInfo.processInfo.environment[menuEnvironmentKey]?.lowercased()
        return ProcessInfo.processInfo.arguments.contains(menuLaunchArgument)
            || env == "1"
            || env == "true"
            || env == "yes"
    }

    static var initialReaderOverlay: ReaderOverlay? {
        let env = ProcessInfo.processInfo.environment[menuEnvironmentKey]?.lowercased()
        if let env, let overlay = ReaderOverlay(rawValue: env) {
            return overlay
        }
        return shouldOpenReaderMenu ? .info : nil
    }

    static var initialNavigationPath: [String] {
        shouldOpenReader ? [initialReaderPath] : []
    }

    static var initialReaderPath: String {
        if let path = ProcessInfo.processInfo.environment[readerPathEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return path
        }
        return defaultReaderPath
    }

    static func prepare(fileManager fm: FileManager = .default) throws -> URL {
        let root = try rootURL(fileManager: fm)
        if fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }

        for file in files {
            let url = root.appendingPathComponent(file.path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.contents.write(to: url, atomically: true, encoding: .utf8)
        }

        try writeSession(at: root, fileManager: fm)
        return root
    }

    static func indexDBPath(workspaceRoot root: URL) -> URL {
        root.appendingPathComponent(".marple/index.sqlite")
    }

    private static func rootURL(fileManager fm: FileManager) throws -> URL {
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                              appropriateFor: nil, create: true)
        return base.appendingPathComponent("MarpleDemoVault", isDirectory: true)
    }

    private static func writeSession(at root: URL, fileManager fm: FileManager) throws {
        let topic = OpenDocSnapshot(path: defaultReaderPath,
                                    title: "技术物形态与维修政制",
                                    type: EntryType.topic.rawValue)
        let note = OpenDocSnapshot(path: "vault/notes/notes.md",
                                   title: "BTS准备",
                                   type: EntryType.note.rawValue)
        let repairPaper = OpenDocSnapshot(path: "vault/papers/kuipers-how-to-be-a-cell-phone-repair-technician-2015.md",
                                          title: "How to be a Cell Phone Repair Technician",
                                          type: EntryType.paper.rawValue)
        let waterPaper = OpenDocSnapshot(path: "vault/papers/yu-water-resistant-smartphone-technologies-2019.md",
                                         title: "Water-Resistant Smartphone Technologies",
                                         type: EntryType.paper.rawValue)
        let yatesBook = OpenDocSnapshot(path: "vault/books/yates-engineering-rules-2019/00-overview.md",
                                        title: "Engineering Rules: Global Standard Setting since 1880",
                                        type: EntryType.book.rawValue)
        let yatesChapter = OpenDocSnapshot(path: "vault/books/yates-engineering-rules-2019/ch04-engineering-professionalization-private-standard-setting-industry-before-1900.md",
                                           title: "第1章 工程职业化与1900年前的工业私有标准制定",
                                           type: EntryType.chapter.rawValue)
        let baldwinBook = OpenDocSnapshot(path: "vault/books/baldwin-design-rules-2000/00-overview.md",
                                          title: "Design Rules: The Power of Modularity (Volume 1)",
                                          type: EntryType.book.rawValue)
        let baldwinChapter = OpenDocSnapshot(path: "vault/books/baldwin-design-rules-2000/ch04-what-is-modularity.md",
                                             title: "第2章 什么是模块化",
                                             type: EntryType.chapter.rawValue)
        let baldwinAuthor = OpenDocSnapshot(path: "vault/authors/carliss-y-baldwin.md",
                                            title: "Carliss Y. Baldwin",
                                            type: EntryType.author.rawValue)
        let ulrichAuthor = OpenDocSnapshot(path: "vault/authors/karl-t-ulrich.md",
                                           title: "Karl T. Ulrich",
                                           type: EntryType.author.rawValue)

        let snap = SessionSnapshot(
            updatedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            spaces: [
                SessionSpaceSnapshot(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    name: "阿尔冯斯",
                    iconName: "hammer.fill",
                    roots: [
                        .doc(topic),
                        .group(name: "手机维修民族志", isCollapsed: false, children: [
                            .doc(repairPaper),
                            .doc(waterPaper),
                            .doc(note),
                        ]),
                        .group(name: "标准与接口", isCollapsed: false, children: [
                            .doc(yatesBook),
                            .doc(yatesChapter),
                            .doc(baldwinBook),
                            .doc(baldwinChapter),
                        ]),
                        .group(name: "作者卡片", isCollapsed: false, children: [
                            .doc(baldwinAuthor),
                            .doc(ulrichAuthor),
                        ]),
                    ],
                    activePath: topic.path
                ),
            ]
        )

        let url = SessionFile.url(workspaceRoot: root.path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snap).write(to: url, options: .atomic)
    }
}

private struct DemoVaultFile {
    let path: String
    let contents: String
}

private let files: [DemoVaultFile] = [
    DemoVaultFile(
        path: "vault/notes/notes.md",
        contents: """
        ---
        type: note
        title: BTS准备
        created: 2026-05-23
        annotates: vault/papers/kuipers-how-to-be-a-cell-phone-repair-technician-2015.md
        topics:
        - repair-morphology-interface-control
        ---

        # BTS准备

        这个 demo 笔记抽取真实 BTS 文库的组织方式: 一个粗粒度准备页会把工程知识、维修民族志、标准化史、模块化理论和手机物理整合放在同一张工作台上。

        ## 当前问题

        - 手机维修不能只写成用户权利,还要写成部件边界、工具、备件、接口和系统承认之间的再接合实践。
        - 标准化也不能只写成制造史,而是要追问谁能定义接口、谁能获得工具、谁的替换会被系统承认。
        - 移动端截图需要这种混合密度: 有长标题、中文摘要、英文文献名、表格、wikilink 和未成文的工作笔记。

        ## 关系

        [[vault/topics/repair-morphology-interface-control/00-overview|技术物形态与维修政制]] 是本轮讨论的入口页。
        [[vault/papers/kuipers-how-to-be-a-cell-phone-repair-technician-2015|How to be a Cell Phone Repair Technician]] 提供维修现场的民族志质感。
        [[vault/books/yates-engineering-rules-2019/00-overview|Engineering Rules]] 和 [[vault/books/baldwin-design-rules-2000/00-overview|Design Rules]] 提供接口与标准的理论骨架。
        """
    ),
    DemoVaultFile(
        path: "vault/topics/repair-morphology-interface-control/00-overview.md",
        contents: """
        ---
        type: topic
        title: 技术物形态与维修政制
        kind: overview
        themes:
        - repair
        - interface-control
        - smartphone-architecture
        ---

        # 技术物形态与维修政制

        本页是一个可导航规划页。中心问题: 以 iPhone 专有螺丝、密封胶、零件配对和诊断工具为入口,把维修理解为由技术物形态、生产制度与社会网络共同规定的再接合实践。

        ## 写作边界

        - 不是单纯维修权檄文: 专有螺丝当然可以被批评,但更重要的是追问为什么“标准工具可进入、标准零件可替换、换件即可修好”会显得那么自然。
        - 不是单线标准化史: 螺纹、量规、互换零件和服务网络彼此纠缠,不能压扁成一条从兵工厂到手机的直线。
        - 不是平台研究优先: 软件锁和授权网络很重要,但入口仍然是手机作为高密度技术物的部件边界、接合方式、可逆性和系统承认。

        ## 维修形态维度

        | 维度 | 工作定义 | 对移动端 UI 的压力 |
        |---|---|---|
        | 部件边界 | 螺丝、卡扣、焊点、胶层、封装或软件身份如何划分部件 | 长表格需要稳定排版 |
        | 接合方式 | 螺丝、粘接、压接、排线、BGA、密封圈或固件绑定 | 大纲 sheet 要能跳到小节 |
        | 系统承认 | 替换件是否被硬件、固件、云服务和授权流程承认为有效 | 信息面板要显示 topic/author 关系 |

        一句话脊柱: **专有螺丝关乎控制接口,不关乎螺丝本身;它把本可由标准工具、标准件和维修生态分享的替代期权,重新收回到整机架构师和授权网络手中。**
        """
    ),
    DemoVaultFile(
        path: "vault/papers/kuipers-how-to-be-a-cell-phone-repair-technician-2015.md",
        contents: """
        ---
        type: paper
        title: How to be a Cell Phone Repair Technician
        authors:
        - Amanda Kemble
        - Briel Kobak
        - Joshua A. Bell
        - Joel C. Kuipers
        year: 2015
        journal: secondary
        themes:
        - citation-snowball
        - smartphone-repair
        doi: 10.7591/9780801456428-014
        topics:
        - repair-morphology-interface-control
        ---

        # 如何成为手机维修技师

        这篇条目在真实库里承担“手机维修民族志”的入口作用。demo 版本保留长作者列表、DOI、主题和中文阅读笔记的形态,让列表、搜索、详情面板和阅读页能暴露真实密度。

        ## 核心论点

        手机维修技师不是单纯替换零件的人。他们在工作台上同时管理工具、顾客信任、隐私数据、零件质量、热风枪手感和不确定的故障叙事。维修店因此成为一个短暂打开黑箱的场所: 手机内部被看见,但这种可见性总是受工具、经验和市场条件限制。

        ## 可用于论文的问题

        - “第一天上班”的操作手册体裁如何展示无法完全写进手册的具身知识?
        - 第三方维修如何让顾客一对一地理解手机内部,又如何重新制造新的依赖关系?
        - 维修者接触的是屏幕、电池和主板,也是照片、聊天记录和亲密关系。
        """
    ),
    DemoVaultFile(
        path: "vault/papers/yu-water-resistant-smartphone-technologies-2019.md",
        contents: """
        ---
        type: paper
        title: Water-Resistant Smartphone Technologies
        authors:
        - Quanqing Yu
        - Rui Xiong
        - Chuan Li
        - Michael G. Pecht
        year: 2019
        journal: IEEE Access
        themes:
        - smartphone water resistance
        - physical sealing
        - IP testing
        - repairability
        doi: 10.1109/ACCESS.2019.2904654
        topics:
        - repair-morphology-interface-control
        ---

        # 防水智能手机技术

        本文把“防水”从营销标签还原为边界工程: 胶、胶条、垫圈、透气膜、声学网格、保形涂层和 IP 测试共同制造一种有限、会退化、维修后难以验证的水阻状态。

        ## 读法

        iPhone、Galaxy 和 Huawei 的拆解材料显示,手机并不是一个完全密封的容器。它必须同时让触摸、按键、插卡、充电、出声、收音、散压和散热发生,所以真正被设计的是一组选择性开放的边界。

        ## 和维修的关系

        维修不是把屏幕打开再合上那么简单。拆解会破坏胶层和垫圈的压缩状态,替换后还需要重建密封、校准和责任边界。移动端阅读页需要能舒服地承载这种“工程清单 + 概念转译”的笔记。
        """
    ),
    DemoVaultFile(
        path: "vault/books/yates-engineering-rules-2019/00-overview.md",
        contents: """
        ---
        type: book
        title: 'Engineering Rules: Global Standard Setting since 1880'
        authors:
        - JoAnne Yates
        - Craig N. Murphy
        year: 2019
        publisher: Johns Hopkins University Press
        isbn: 9781421428895
        category: monograph
        themes:
        - voluntary-standardization
        - consensus-governance
        - screw-threads-interchangeability
        topics:
        - repair-morphology-interface-control
        rating: ★★★★
        ---

        # Engineering Rules: Global Standard Setting since 1880

        Yates 和 Murphy 把标准制定写成一套隐形的全球经济治理基础设施。对本项目最关键的是螺纹和紧固件标准化: 它让互换性、维修、库存和跨厂协作变成可以协调的公共问题。

        ## 读书定位

        - Whitworth 与 Sellers 的螺纹标准说明,标准化常常追求“最可接受”而不是技术最优。
        - 集装箱标准是开放接口扩大网络的正面案例。
        - 专有螺丝可以作为强势参与者选择性退出公共标准治理的反面案例。
        """
    ),
    DemoVaultFile(
        path: "vault/books/yates-engineering-rules-2019/ch04-engineering-professionalization-private-standard-setting-industry-before-1900.md",
        contents: """
        ---
        type: chapter
        title: 第1章 工程职业化与1900年前的工业私有标准制定
        authors:
        - JoAnne Yates
        - Craig N. Murphy
        year: 2019
        book: yates-engineering-rules-2019
        themes:
        - standardization-history
        - screw-threads
        - voluntary-standards
        topics:
        - repair-morphology-interface-control
        ---

        # 第1章 工程职业化与1900年前的工业私有标准制定

        本章从工程职业化出发,讲蒸汽锅炉、螺钉螺纹和钢轨如何进入工程师学会的标准制定议程。它适合放在 iPhone 专有螺丝之前,作为“接口为何需要公共协调”的历史参照。

        ## 摘要

        Whitworth 在 1841 年提出统一螺纹系统时,并不是发明一个孤立的最佳形状,而是在已有车间实践之间寻找可被广泛接受的共同规格。Sellers 在美国推广另一套更易制造的标准,说明标准化一开始就是技术、机构声望、大用户采纳和产业扩散共同作用的结果。
        """
    ),
    DemoVaultFile(
        path: "vault/books/baldwin-design-rules-2000/00-overview.md",
        contents: """
        ---
        type: book
        title: 'Design Rules: The Power of Modularity (Volume 1)'
        authors:
        - Carliss Y. Baldwin
        - Kim B. Clark
        year: 2000
        publisher: MIT Press
        isbn: 0-262-02466-7
        category: monograph
        themes:
        - modularity
        - design-rules
        - real-options
        - interface-control
        topics:
        - repair-morphology-interface-control
        rating: 5
        ---

        # Design Rules: The Power of Modularity (Volume 1)

        Baldwin 和 Clark 的关键贡献是把接口写成设计规则的载体。接口规定模块之间如何连接、替换、测试和被承认,因此也规定谁能参与系统、谁能捕获期权价值。

        ## 对维修项目的用法

        专有紧固件可以被读作对物理接口的去标准化操作: 它把本应公开可见的进入点转入厂商控制域。手机内部可以为生产高度模块化,同时对使用者和第三方维修者保持选择性封闭。
        """
    ),
    DemoVaultFile(
        path: "vault/books/baldwin-design-rules-2000/ch04-what-is-modularity.md",
        contents: """
        ---
        type: chapter
        title: 第2章 什么是模块化
        authors:
        - Carliss Y. Baldwin
        - Kim B. Clark
        year: 2000
        book: baldwin-design-rules-2000
        themes:
        - modularity
        - design-rules
        - interface-specification
        topics:
        - repair-morphology-interface-control
        ---

        # 第2章 什么是模块化

        本章定义模块化: 模块内部强连接,模块之间弱连接;通过抽象、信息隐藏和接口来管理复杂性。对手机维修而言,重点不是“有没有独立部件”,而是接口是否足够公开、稳定、可测试。

        ## 三件事

        1. 架构定义系统由哪些模块构成。
        2. 接口描述模块之间如何连接、通信和解决冲突。
        3. 集成协议与测试标准规定何时算作装好、何时算作正常。

        这正好对应手机维修中的拆开、换上、校准和被系统承认。
        """
    ),
    DemoVaultFile(
        path: "vault/authors/carliss-y-baldwin.md",
        contents: """
        ---
        type: author
        name: Carliss Y. Baldwin
        title: Carliss Y. Baldwin
        themes:
        - design-rules
        - modularity
        - interface-control
        - real-options
        rating: 5
        ---

        # Carliss Y. Baldwin

        Baldwin 适合用于分析标准、接口、维修权、平台封闭和产业分工。她的框架能把一个看似微小的物理接口,例如螺丝头型、排线连接器或诊断协议,放入更大的架构逻辑中。
        """
    ),
    DemoVaultFile(
        path: "vault/authors/karl-t-ulrich.md",
        contents: """
        ---
        type: author
        name: Karl T. Ulrich
        title: Karl T. Ulrich
        themes:
        - product-architecture
        - product-modularity
        - interface-standardization
        - repairability
        ---

        # Karl T. Ulrich

        Ulrich 的产品架构框架把功能、物理组件和接口 specification 放在一起分析。它提醒我们: 有组件边界不等于开放互换,可拆装也不等于第三方维修可以稳定完成。
        """
    ),
]
#endif
