import Testing
import Foundation
@testable import MarpleKit

/// Latency floor for the ⌘T command-palette fast ranker. Not strict pass/fail —
/// the goal is to keep numbers visible in test output so regressions surface
/// when running `swift test --filter SearchRankerBenchmark`. The threshold is
/// generous (2x what we target) to avoid CI flakes on shared runners.
@Suite struct SearchRankerBenchmarkTests {
    /// Synthetic 15k corpus that mirrors the real distribution: ~70% latin
    /// papers, ~30% CJK book/topic entries, varied field fill.
    static let corpus: SearchIndex = buildSearchIndex(makeSyntheticEntries(15_000))

    @Test func benchmarkTypicalQueries() {
        let queries: [(String, String)] = [
            ("ASCII prefix",      "machine"),
            ("ASCII two-token",   "machine learning"),
            ("CJK token",         "量表"),
            ("CJK two-token",     "量表 测量"),
            ("Mixed",             "android 测量"),
            ("Short token",       "ma"),
            ("Long phrase",       "convolutional neural network"),
            ("DOI",               "10.1000/xyz123"),
        ]

        print("\n--- SearchRanker (15k docs) ---")
        let index = Self.corpus
        for (label, q) in queries {
            // Warm caches once so the first run's allocator doesn't dominate.
            _ = searchDocuments(index, q)
            let clock = ContinuousClock()
            var samples: [Duration] = []
            for _ in 0..<5 {
                let t = clock.measure { _ = searchDocuments(index, q) }
                samples.append(t)
            }
            let medMs = median(samples).asMs
            let pad = String(repeating: " ", count: max(0, 22 - label.count))
            let qf = "\"\(q)\""
            let qpad = String(repeating: " ", count: max(0, 32 - qf.count))
            print("  \(label)\(pad)  \(qf)\(qpad)  median \(String(format: "%.2f", medMs)) ms")
            #expect(medMs < 500, "fast-mode rank for \"\(q)\" too slow at \(medMs) ms")
        }
        print("----------------------------------------\n")
    }

    private func median(_ ds: [Duration]) -> Duration {
        let sorted = ds.sorted()
        return sorted[sorted.count / 2]
    }
}

private extension Duration {
    var asMs: Double {
        let c = components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }
}

/// 15k entries that look like the real vault: latin paper titles + CJK book
/// titles + topic notes, all 10 ranker fields filled to varying degrees.
func makeSyntheticEntries(_ n: Int) -> [Entry] {
    let latinTitleParts = [
        "Deep", "Convolutional", "Neural", "Network", "for", "Machine", "Learning",
        "Quantum", "Mechanics", "Reinforcement", "Bayesian", "Statistical", "Inference",
        "Transformer", "Attention", "Graph", "Embedding", "Survey", "Analysis",
        "Causal", "Optimization", "Algorithm", "Dataset", "Benchmark",
    ]
    let authors = [
        "Hinton G.", "LeCun Y.", "Bengio Y.", "Goodfellow I.", "Schmidhuber J.",
        "Vaswani A.", "Sutskever I.", "Ng A.", "Murphy K.", "Bishop C.",
    ]
    let themes = [
        "machine-learning", "vision", "nlp", "rl", "theory", "systems", "infra",
        "ethics", "alignment", "scaling-laws",
    ]
    let cjkTitleParts = [
        "量表", "测量", "方法", "理论", "框架", "实证", "研究", "综述", "分析",
        "社会", "心理", "教育", "认知", "发展", "比较", "跨文化",
    ]
    let topics = ["topic-a", "topic-b", "topic-c", "topic-d", "topic-e"]
    let sources = ["NeurIPS", "ICML", "ICLR", "CVPR", "ACL", "Nature", "Science"]
    let books = ["Pattern Recognition", "深度学习", "统计学习方法", "量化研究方法"]

    var out: [Entry] = []
    out.reserveCapacity(n)
    var rng = SplitMix64(seed: 0xC0FFEE)
    for i in 0..<n {
        let isCJK = rng.next() % 10 < 3
        let title: String
        let author: [String]
        let book: String?
        if isCJK {
            let a = cjkTitleParts[Int(rng.next() % UInt64(cjkTitleParts.count))]
            let b = cjkTitleParts[Int(rng.next() % UInt64(cjkTitleParts.count))]
            title = "\(a)的\(b)研究 \(i)"
            author = ["作者\(i % 200)"]
            book = books[Int(rng.next() % UInt64(books.count))]
        } else {
            let a = latinTitleParts[Int(rng.next() % UInt64(latinTitleParts.count))]
            let b = latinTitleParts[Int(rng.next() % UInt64(latinTitleParts.count))]
            let c = latinTitleParts[Int(rng.next() % UInt64(latinTitleParts.count))]
            title = "\(a) \(b) \(c) \(i)"
            author = [authors[Int(rng.next() % UInt64(authors.count))]]
            book = nil
        }
        let theme = themes[Int(rng.next() % UInt64(themes.count))]
        let topic = topics[Int(rng.next() % UInt64(topics.count))]
        let source = sources[Int(rng.next() % UInt64(sources.count))]
        let year = String(1990 + Int(rng.next() % 35))
        let preview = "Abstract excerpt for entry \(i): \(title.lowercased()) discussion."
        let doi = isCJK ? nil : "10.1000/xyz\(i)"
        let path = "vault/\(isCJK ? "books" : "papers")/entry-\(i).md"
        out.append(Entry(
            path: path,
            type: isCJK ? .book : .paper,
            title: title,
            author: author,
            year: year,
            ratingScore: Double(i % 5),
            themes: [theme],
            topics: [topic],
            preview: preview,
            hasPDF: false,
            source: source,
            book: book,
            doi: doi
        ))
    }
    return out
}

/// Deterministic PRNG so benchmark numbers are run-to-run comparable.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z &>> 27)) &* 0x94D049BB133111EB
        return z ^ (z &>> 31)
    }
}
