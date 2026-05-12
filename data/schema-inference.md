# qua-vault schema inference

Generated: 2026-05-11T16:43:14.174Z
Types: 5, total typed entries: 10760

Field tag legend: **req** = filled in ≥97% of entries · **opt** = 50–97% · **rare** = <50%

## `chapter-summary` — 8093 entries

- `author` **req** · fill 100% / non-null 100% · string×4471 array×3622 · array · avg 1.2 items, max 7 · 500+ unique elements
- `year` **req** · fill 100% / non-null 100% · number×8080 string×13 · number · range 1934..2025
- `title` **req** · fill 100% / non-null 100% · string×8090 · 500+ unique · e.g. "第1章 前言", "第1章 导论", "第2章 实践中的隐喻"
- `themes` **rare** · fill 99% / non-null 31% · array×8049 · array · avg 5.6 items, max 15 · 500+ unique elements
- `relevance` **opt** · fill 99% / non-null 97% · number×7812 string×2 · number · range 0..1968
- `source` **req** · fill 99% / non-null 99% · string×8049 · 500+ unique · e.g. "Computation and Human Experience", "Computation and Human Experience", "Computation and Human Experience"
- `rating` **rare** · fill 99% / non-null 21% · string×1234 number×456 · number · range 1..9
- `chapter` **opt** · fill 68% / non-null 68% · number×5472 string×40 · number · range -1..2004
- `slot` **rare** · fill 32% / non-null 32% · string×2578 number×4 · number · range 0..99
- `book` **rare** · fill 1% / non-null 1% · string×44 · ENUM (6) · { Feminist Disability Studies (H… | Pilgrimages/Peregrinajes | [[mol-care-practice-2010|Care … | Crip Authorship: Disability as… | The Critique of Coloniality | The Rejected Body: Feminist Ph… }
- `publisher` **rare** · fill 0% / non-null 0% · string×7 · ENUM (3) · { Princeton University Press | Duke University Press | Routledge }
- `topics` **rare** · fill 0% / non-null 0% · array×6 · array · avg 6.7 items, max 9 · 30 unique elements
- `pages` **rare** · fill 0% / non-null 0% · string×3 · ENUM (3) · { 122-148 | 183-205 | 10-20 }
- `tags` **rare** · fill 0% / non-null 0% · array×3 · array · avg 7.3 items, max 8 · 20 unique elements
- `chapter_title` **rare** · fill 0% / non-null 0% · string×2 · ENUM (2) · { Enticements and Dangers of Com… | Introduction }
- `chapter-author` **rare** · fill 0% / non-null 0% · string×1 · ENUM (1) · { Deborah Gambs }
- `editors` **rare** · fill 0% / non-null 0% · string×1 · ENUM (1) · { Maria Lugones }
- `topic` **rare** · fill 0% / non-null 0% · string×1 · ENUM (1) · { intersectionality and colonial… }
- `book_title` **rare** · fill 0% / non-null 0% · string×1 · ENUM (1) · { The Rejected Body: Feminist Ph… }
- `chapter_label` **rare** · fill 0% / non-null 0% · string×1 · ENUM (1) · { Introduction }
- `word_count_est` **rare** · fill 0% / non-null 0% · string×1 · ENUM (1) · { ~4500 }
- `status` **rare** · fill 0% / non-null 0% · string×1 · ENUM (1) · { analyzed }

## `paper-analysis` — 1651 entries

- `doi` **req** · fill 100% / non-null 98% · string×1614 · 500+ unique · e.g. "", "", ""
- `title` **req** · fill 99% / non-null 99% · string×1632 · 500+ unique · e.g. "第1章 导论", "第2章 逻辑加经验主义", "第3章 归纳与确认"
- `source` **opt** · fill 89% / non-null 82% · string×1359 · 500+ unique · e.g. "Theory and Reality: An Introduction to the Philoso…", "Theory and Reality: An Introduction to the Philoso…", "Theory and Reality: An Introduction to the Philoso…"
- `author` **opt** · fill 87% / non-null 87% · string×1241 array×200 · array · avg 1.0 items, max 2 · 500+ unique elements
- `year` **opt** · fill 87% / non-null 87% · number×1441 · number · range 1938..2026
- `rating` **rare** · fill 87% / non-null 46% · string×515 number×246 · number · range 1..5
- `themes` **rare** · fill 87% / non-null 49% · array×1385 string×50 · array · avg 5.7 items, max 13 · 500+ unique elements
- `tags` **rare** · fill 13% / non-null 6% · array×91 · array · avg 2.0 items, max 10 · 76 unique elements
- `authors` **rare** · fill 13% / non-null 13% · array×88 string×122 · array · avg 1.1 items, max 3 · 194 unique elements
- `date` **rare** · fill 13% / non-null 13% · string×146 number×64 · number · range 1979..2026
- `journal` **rare** · fill 10% / non-null 10% · string×163 · ENUM (8) · { British Journal of Sociology | Critical Inquiry | Engaging Science, Technology, … | Social Epistemology | Journal of Visual Culture | Theory, Culture & Society | Nordic Journal of Aesthetics | Political Theory }
- `score` **rare** · fill 9% / non-null 9% · number×66 string×79 · number · range 5..9
- `topic` **rare** · fill 3% / non-null 3% · string×52 · ENUM (4) · { 技术、AI、媒介与具身化 | Archer vs. Giddens debate on s… | Durkheim social morphology | smartphone repair }
- `concepts` **rare** · fill 2% / non-null 2% · array×40 · array · avg 1.1 items, max 2 · 31 unique elements
- `round` **rare** · fill 2% / non-null 2% · number×38 · number · range 0..3
- `paper_title` **rare** · fill 1% / non-null 1% · string×19 · 19 unique · e.g. "Eclipse of the Spectacle", "Active inference, enactivism and the hermeneutics …", "A pattern theory of self"
- `source_type` **rare** · fill 1% / non-null 1% · string×14 · ENUM (1) · { snowball-paper }
- `terminal` **rare** · fill 0% / non-null 0% · string×6 · ENUM (1) · { true }
- `reviewed_book` **rare** · fill 0% / non-null 0% ·  · 0 unique
- `relevance` **rare** · fill 0% / non-null 0% · number×1 string×1 · number · range 2..2
- `status` **rare** · fill 0% / non-null 0% · string×2 · ENUM (1) · { error }
- `notes` **rare** · fill 0% / non-null 0% · string×2 · ENUM (2) · { PDF 文本提取失败（疑似图像/扫描版），需 OCR 或人工… | PDF 文本提取失败（疑似扫描版/图像 PDF），pdfto… }
- `translators` **rare** · fill 0% / non-null 0% · string×1 · ENUM (1) · { Bernard Dionysius Geoghegan, C… }
- `reviewed_author` **rare** · fill 0% / non-null 0% · string×1 · ENUM (1) · { Ramesh Srinivasan }
- `volume` **rare** · fill 0% / non-null 0% · string×1 · ENUM (1) · { 20(3) }
- `pages` **rare** · fill 0% / non-null 0% · string×1 · ENUM (1) · { 371-398 }
- `citations` **rare** · fill 0% / non-null 0% · number×1 · number · range 120..120
- `note` **rare** · fill 0% / non-null 0% · string×1 · ENUM (1) · { PDF文件内容错误——下载到Sam Binkley的'The… }

## `book-overview` — 779 entries

- `title` **req** · fill 99% / non-null 99% · string×769 · 500+ unique · e.g. "Computation and Human Experience", "Sara Ahmed, *The Cultural Politics of Emotion*", "Sara Ahmed, *Living a Feminist Life* (2017) — 书籍概览"
- `topic` **opt** · fill 84% / non-null 84% · string×657 · 179 unique · e.g. "技术、AI、媒介与具身化", "技术、AI、媒介与具身化", "技术、AI、媒介与具身化"
- `chapters_analyzed` **opt** · fill 83% / non-null 83% · number×648 · number · range 0..69
- `author` **rare** · fill 46% / non-null 46% · array×328 string×33 · array · avg 1.1 items, max 4 · 190 unique elements
- `year` **rare** · fill 44% / non-null 40% · number×315 · number · range 1960..2025
- `themes` **rare** · fill 15% / non-null 8% · array×116 · array · avg 7.7 items, max 12 · 407 unique elements
- `rating` **rare** · fill 14% / non-null 6% · number×22 string×27 · number · range 3..5
- `source` **rare** · fill 9% / non-null 9% · string×70 · 30 unique · e.g. "", "", ""
- `publisher` **rare** · fill 6% / non-null 6% · string×50 · 26 unique · e.g. "Duke University Press", "Polity Press", "Polity Press"
- `total_chapters` **rare** · fill 3% / non-null 3% · number×22 · number · range 5..35
- `relevance` **rare** · fill 3% / non-null 3% · number×21 · number · range 2..5
- `has-overview` **rare** · fill 2% / non-null 2% · string×18 · ENUM (1) · { true }
- `analyzed_chapters` **rare** · fill 2% / non-null 2% · number×13 · number · range 4..9
- `tags` **rare** · fill 2% / non-null 0% · array×3 · array · avg 7.0 items, max 8 · 19 unique elements
- `book_title` **rare** · fill 1% / non-null 1% · string×9 · ENUM (9) · { Governing through Biometrics: … | Meeting the Universe Halfway | Race After Technology | Metamorphoses: Towards a Mater… | Nomadic Subjects: Embodiment a… | 24/7: Late Capitalism and the … | Techniques of the Observer: On… | Being Singular Plural | Before the Law: Humans and Oth… }
- `authors` **rare** · fill 1% / non-null 1% · array×1 string×5 · array · avg 2.0 items, max 2 · 5 unique elements
- `editors` **rare** · fill 1% / non-null 1% · string×3 array×1 · array · avg 2.0 items, max 2 · 5 unique elements
- `source_type` **rare** · fill 1% / non-null 1% · string×4 · ENUM (1) · { snowball-book }
- `date` **rare** · fill 1% / non-null 1% · number×4 · number · range 1995..2004
- `selection_note` **rare** · fill 0% / non-null 0% · string×2 · ENUM (2) · { vault 选读 ch01 (导论) + ch09 (Moo… | vault 仅选读了同名章节 ch01 Duty-Free … }
- `concepts` **rare** · fill 0% / non-null 0% · array×2 · array · avg 1.0 items, max 1 · 2 unique elements
- `slug` **rare** · fill 0% / non-null 0% · string×2 · ENUM (2) · { block-occupying-disability-201… | patricia-maccormack-posthuman-… }
- `chapters_total` **rare** · fill 0% / non-null 0% · number×2 · number · range 12..49
- `selective_reading` **rare** · fill 0% / non-null 0% · string×2 · ENUM (1) · { true }
- `scope_note` **rare** · fill 0% / non-null 0% · string×2 · ENUM (2) · { 本目录仅收录 Luciana Parisi 撰写的一章 (A… | 本 vault 目录只收录 Luciana Parisi 的… }
- `source_file` **rare** · fill 0% / non-null 0% · string×2 · ENUM (2) · { sources/giddens-constitution-o… | sources/giddens-modernity-self… }
- `analyzed` **rare** · fill 0% / non-null 0% · string×2 · ENUM (1) · { 2026-02-27 }
- `confidence` **rare** · fill 0% / non-null 0% · number×2 · number · range 0.92..0.95
- `chapters_available` **rare** · fill 0% / non-null 0% · array×1 · array · avg 9.0 items, max 9 · 9 unique elements
- `chapters_missing` **rare** · fill 0% / non-null 0% · array×1 · array · avg 3.0 items, max 3 · 3 unique elements
- `chapters_in_volume` **rare** · fill 0% / non-null 0% · number×1 · number · range 13..13
- `chapters_in_vault` **rare** · fill 0% / non-null 0% · array×1 · array · avg 1.0 items, max 1 · 1 unique elements
- `source_note` **rare** · fill 0% / non-null 0% · string×1 · ENUM (1) · { 基于1988年发表于October (Vol. 45, pp… }
- `overall_rating` **rare** · fill 0% / non-null 0% · string×1 · ENUM (1) · { ★★★ }
- `status` **rare** · fill 0% / non-null 0% · string×1 · ENUM (1) · { overview-complete }
- `processed_chapters` **rare** · fill 0% / non-null 0% · number×1 · number · range 8..8
- `book_author` **rare** · fill 0% / non-null 0% · string×1 · ENUM (1) · { Jean-Luc Nancy }
- `book_year` **rare** · fill 0% / non-null 0% · number×1 · number · range 2000..2000
- `avg_relevance` **rare** · fill 0% / non-null 0% · number×1 · number · range 2.4..2.4
- `book` **rare** · fill 0% / non-null 0% · string×1 · ENUM (1) · { The Critique of Coloniality }
- `topics` **rare** · fill 0% / non-null 0% · array×1 · array · avg 6.0 items, max 6 · 6 unique elements
- `chapters_selected` **rare** · fill 0% / non-null 0% · number×1 · number · range 1..1
- `edition` **rare** · fill 0% / non-null 0% · string×1 · ENUM (1) · { 2nd Edition }
- `structure` **rare** · fill 0% / non-null 0% · string×1 · ENUM (1) · { 双层结构：1st Edition 正文 (ch02-ch10… }

## `author-profile` — 229 entries

- `rating` **rare** · fill 100% / non-null 17% · number×30 string×10 · number · range 2..5
- `themes` **opt** · fill 100% / non-null 90% · array×224 string×5 · array · avg 8.3 items, max 19 · 500+ unique elements
- `author` **req** · fill 100% / non-null 100% · string×205 array×24 · array · avg 1.0 items, max 1 · 227 unique elements
- `title` **req** · fill 100% / non-null 100% · string×229 · 227 unique · e.g. "Adele Clarke", "Adrian Mackenzie", "Aimi Hamraie"
- `year` **rare** · fill 100% / non-null 8% · string×17 number×2 · number · range 0..2026
- `source` **rare** · fill 100% / non-null 7% · string×14 array×1 · array · avg 2.0 items, max 2 · 15 unique elements
- `has-profile` **rare** · fill 3% / non-null 3% · string×8 · ENUM (1) · { true }

## `topic-synthesis` — 8 entries

- `topic` **opt** · fill 75% / non-null 75% · string×6 · ENUM (5) · { 技术、AI、媒介与具身化 | 密码学的社会建构 | Archer vs. Giddens debate on s… | iPhone 中专有螺丝（Pentalobe / Y0.6 … | smartphone repair }
- `date` **opt** · fill 50% / non-null 50% · string×4 · ENUM (4) · { 2026-02-27 | 2026-04-30 | 2026-04-29 | 2026-02-20 }
- `rounds` **rare** · fill 38% / non-null 38% · number×3 · number · range 2..4
- `papers_analyzed` **rare** · fill 25% / non-null 25% · number×2 · number · range 13..18
- `topic_slug` **rare** · fill 25% / non-null 25% · string×2 · ENUM (2) · { social-construction-cryptograp… | archer-giddens-morphology }
- `total_papers` **rare** · fill 25% / non-null 25% · number×2 · number · range 27..38
- `tags` **rare** · fill 25% / non-null 0% ·  · 0 unique
- `journal` **rare** · fill 13% / non-null 13% · string×1 · ENUM (1) · { Qualitative Sociology }
- `papers_total` **rare** · fill 13% / non-null 13% · number×1 · number · range 13..13
- `seed` **rare** · fill 13% / non-null 13% · string×1 · ENUM (1) · { King (2010) The odd couple }
- `status` **rare** · fill 13% / non-null 13% · string×1 · ENUM (1) · { working }
- `themes` **rare** · fill 13% / non-null 13% · array×1 · array · avg 9.0 items, max 9 · 9 unique elements
- `author_focus` **rare** · fill 13% / non-null 13% · string×1 · ENUM (1) · { Robert B. Gordon }
- `primary_sources` **rare** · fill 13% / non-null 13% · array×1 · array · avg 5.0 items, max 5 · 5 unique elements
- `books` **rare** · fill 13% / non-null 13% · array×1 · array · avg 2.0 items, max 2 · 2 unique elements
- `relevance` **rare** · fill 13% / non-null 13% · string×1 · ENUM (1) · { 维修作为生产的影子 — 可维修性的历史条件性 }
- `version` **rare** · fill 13% / non-null 13% · string×1 · ENUM (1) · { v3 }
- `supersedes` **rare** · fill 13% / non-null 13% · string×1 · ENUM (1) · { v2 }
- `total_books` **rare** · fill 13% / non-null 13% · number×1 · number · range 10..10

## cross-type field map

- `themes` → `chapter-summary`, `paper-analysis`, `book-overview`, `author-profile`, `topic-synthesis`
- `author` → `chapter-summary`, `paper-analysis`, `book-overview`, `author-profile`
- `rating` → `chapter-summary`, `paper-analysis`, `book-overview`, `author-profile`
- `relevance` → `chapter-summary`, `paper-analysis`, `book-overview`, `topic-synthesis`
- `source` → `chapter-summary`, `paper-analysis`, `book-overview`, `author-profile`
- `status` → `chapter-summary`, `paper-analysis`, `book-overview`, `topic-synthesis`
- `tags` → `chapter-summary`, `paper-analysis`, `book-overview`, `topic-synthesis`
- `title` → `chapter-summary`, `paper-analysis`, `book-overview`, `author-profile`
- `topic` → `chapter-summary`, `paper-analysis`, `book-overview`, `topic-synthesis`
- `year` → `chapter-summary`, `paper-analysis`, `book-overview`, `author-profile`
- `date` → `paper-analysis`, `book-overview`, `topic-synthesis`
- `authors` → `paper-analysis`, `book-overview`
- `book` → `chapter-summary`, `book-overview`
- `book_title` → `chapter-summary`, `book-overview`
- `concepts` → `paper-analysis`, `book-overview`
- `editors` → `chapter-summary`, `book-overview`
- `journal` → `paper-analysis`, `topic-synthesis`
- `pages` → `chapter-summary`, `paper-analysis`
- `publisher` → `chapter-summary`, `book-overview`
- `source_type` → `paper-analysis`, `book-overview`
- `topics` → `chapter-summary`, `book-overview`
- `analyzed` → `book-overview`
- `analyzed_chapters` → `book-overview`
- `author_focus` → `topic-synthesis`
- `avg_relevance` → `book-overview`
- `book_author` → `book-overview`
- `book_year` → `book-overview`
- `books` → `topic-synthesis`
- `chapter` → `chapter-summary`
- `chapter_label` → `chapter-summary`
- `chapter_title` → `chapter-summary`
- `chapter-author` → `chapter-summary`
- `chapters_analyzed` → `book-overview`
- `chapters_available` → `book-overview`
- `chapters_in_vault` → `book-overview`
- `chapters_in_volume` → `book-overview`
- `chapters_missing` → `book-overview`
- `chapters_selected` → `book-overview`
- `chapters_total` → `book-overview`
- `citations` → `paper-analysis`
- `confidence` → `book-overview`
- `doi` → `paper-analysis`
- `edition` → `book-overview`
- `has-overview` → `book-overview`
- `has-profile` → `author-profile`
- `note` → `paper-analysis`
- `notes` → `paper-analysis`
- `overall_rating` → `book-overview`
- `paper_title` → `paper-analysis`
- `papers_analyzed` → `topic-synthesis`
- `papers_total` → `topic-synthesis`
- `primary_sources` → `topic-synthesis`
- `processed_chapters` → `book-overview`
- `reviewed_author` → `paper-analysis`
- `reviewed_book` → `paper-analysis`
- `round` → `paper-analysis`
- `rounds` → `topic-synthesis`
- `scope_note` → `book-overview`
- `score` → `paper-analysis`
- `seed` → `topic-synthesis`
- `selection_note` → `book-overview`
- `selective_reading` → `book-overview`
- `slot` → `chapter-summary`
- `slug` → `book-overview`
- `source_file` → `book-overview`
- `source_note` → `book-overview`
- `structure` → `book-overview`
- `supersedes` → `topic-synthesis`
- `terminal` → `paper-analysis`
- `topic_slug` → `topic-synthesis`
- `total_books` → `topic-synthesis`
- `total_chapters` → `book-overview`
- `total_papers` → `topic-synthesis`
- `translators` → `paper-analysis`
- `version` → `topic-synthesis`
- `volume` → `paper-analysis`
- `word_count_est` → `chapter-summary`