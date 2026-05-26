import Foundation
import MarpleKit
import MarpleEmbeddings

// Standalone semantic-search CLI over a marple workspace. Lets you build the
// vector index and query it without the GUI. Needs `default.metallib` at the
// package root (see .gitignore) so MLX finds its Metal lib under `swift run`.
//
//   swift run semantic-tool build <workspace>
//   swift run semantic-tool query <workspace> "<text>" [topK]

setvbuf(stdout, nil, _IONBF, 0)   // unbuffered: progress shows live, even through a pipe

let MODEL = "mlx-community/Qwen3-Embedding-0.6B-8bit"

func die(_ msg: String) -> Never { FileHandle.standardError.write(Data((msg + "\n").utf8)); exit(1) }

func usage() -> Never {
    die("""
    usage:
      semantic-tool build <workspace>
      semantic-tool query <workspace> "<text>" [topK]
      semantic-tool bench <workspace>          # QUA-102/104: time buildFull + loadEntries
    """)
}

/// Embeddable text for an entry: title + body with YAML frontmatter stripped,
/// capped (the embedder also caps tokens; this avoids tokenizing huge files).
func embedText(workspaceRoot: String, entry: Entry, cap: Int = 2000) -> String {
    let url = URL(fileURLWithPath: workspaceRoot).appendingPathComponent(entry.path)
    var body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    if body.hasPrefix("---") {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        if let end = lines.dropFirst().firstIndex(where: { $0 == "---" }) {
            body = lines[(end + 1)...].joined(separator: "\n")
        }
    }
    let title = entry.title ?? ""
    let text = (title.isEmpty ? "" : title + "\n") + body
    return String(text.prefix(cap)).trimmingCharacters(in: .whitespacesAndNewlines)
}

let args = CommandLine.arguments
guard args.count >= 3 else { usage() }
let cmd = args[1]
let workspaceArg = args[2]

let (workspaceRoot, _) = try resolveWorkspace(pickedPath: workspaceArg)
let marpleDir = URL(fileURLWithPath: workspaceRoot).appendingPathComponent(".marple")
let indexPath = marpleDir.appendingPathComponent("index.sqlite").path

// `bench` runs before loadEntries so it can build a fresh index from scratch.
if cmd == "bench" {
    let indexer = VaultIndexer(workspaceRoot: workspaceRoot)
    print("# QUA-102 bench on \(workspaceRoot)")

    // 1. Force a full rebuild (delete any existing index first so we measure
    //    the cold buildFull path, not a delta reconcile).
    let fm = FileManager.default
    if fm.fileExists(atPath: indexPath) {
        let oldSize = (try? fm.attributesOfItem(atPath: indexPath)[.size] as? Int) ?? 0
        print("  pre-existing index: \(oldSize / 1_000_000) MB — removing")
        try? fm.removeItem(atPath: indexPath)
        try? fm.removeItem(atPath: indexPath + "-wal")
        try? fm.removeItem(atPath: indexPath + "-shm")
    }
    let buildStart = Date()
    let count = try indexer.buildFull()
    let buildSecs = Date().timeIntervalSince(buildStart)
    let newSize = (try? fm.attributesOfItem(atPath: indexPath)[.size] as? Int) ?? 0
    print(String(format: "  buildFull: %d entries in %.2fs → DB %d MB",
                 count, buildSecs, newSize / 1_000_000))

    // 2. Cold loadEntries: open a fresh IndexDatabase value (no shared queue)
    //    after purging the OS page cache via `sudo purge` is the gold standard,
    //    but we don't want sudo here — instead drop and re-create the value so
    //    at least the GRDB connection is cold.
    let coldStart = Date()
    let coldEntries = try IndexDatabase(indexDBPath: indexPath).loadEntries()
    let coldSecs = Date().timeIntervalSince(coldStart)
    print(String(format: "  loadEntries cold (fresh queue): %d entries in %.0f ms",
                 coldEntries.count, coldSecs * 1000))

    // 3. Warm loadEntries on the same IndexDatabase value (reuses the queue).
    let warmDB = IndexDatabase(indexDBPath: indexPath)
    _ = try warmDB.loadEntries()
    let warmStart = Date()
    let warmEntries = try warmDB.loadEntries()
    let warmSecs = Date().timeIntervalSince(warmStart)
    print(String(format: "  loadEntries warm (shared queue): %d entries in %.0f ms",
                 warmEntries.count, warmSecs * 1000))

    // 4. Wait for the async cache write triggered by step 2 to land,
    //    then time a fresh-queue load that should hit the cache (QUA-104).
    let cachePath = marpleDir.appendingPathComponent("entries.cache").path
    let waitDeadline = Date().addingTimeInterval(5.0)
    while !fm.fileExists(atPath: cachePath), Date() < waitDeadline {
        try await Task.sleep(nanoseconds: 50_000_000) // 50 ms
    }
    if let cacheSize = (try? fm.attributesOfItem(atPath: cachePath)[.size] as? Int) {
        print("  cache file: \(cacheSize / 1_000_000) MB")
    } else {
        print("  cache file: not written (skipping cache-hit bench)")
        exit(0)
    }

    let hitStart = Date()
    let hitEntries = try IndexDatabase(indexDBPath: indexPath).loadEntries()
    let hitSecs = Date().timeIntervalSince(hitStart)
    print(String(format: "  loadEntries cold-hit (cache present): %d entries in %.0f ms",
                 hitEntries.count, hitSecs * 1000))
    exit(0)
}

let indexDB = IndexDatabase(indexDBPath: indexPath)
let entries = try indexDB.loadEntries()
guard !entries.isEmpty else { die("no entries in index — run the app's indexer first") }

switch cmd {
case "build":
    print("loading embedder (\(MODEL)) …")
    let embedder = try await MLXTextEmbedder(modelId: MODEL)
    let docs = entries.map { SemanticDoc(path: $0.path, text: embedText(workspaceRoot: workspaceRoot, entry: $0)) }
    print("building vector index for \(docs.count) docs …")
    let start = Date()
    let result = try await SemanticIndexer(embedder: embedder).build(
        dir: marpleDir, model: MODEL, docs: docs, batchSize: 64
    ) { done, total in
        if done % 512 == 0 || done == total { print("  embedded \(done)/\(total)") }
    }
    print("done in \(Int(Date().timeIntervalSince(start)))s — embedded \(result.embedded), reused \(result.reused), total \(result.total)")

case "query":
    guard args.count >= 4 else { usage() }
    let q = args[3]
    let topK = args.count >= 5 ? (Int(args[4]) ?? 20) : 20
    guard let loaded = try VectorIndexIO.read(dir: marpleDir) else {
        die("no vector index — run `semantic-tool build \(workspaceArg)` first")
    }
    let embedder = try await MLXTextEmbedder(modelId: MODEL)
    let hits = try await SemanticSearcher(embedder: embedder, store: loaded.store).search(q, topK: topK)
    let titleByPath = Dictionary(entries.map { ($0.path, $0.title ?? "") }, uniquingKeysWith: { a, _ in a })
    print("top \(hits.count) for: \(q)\n")
    for (i, h) in hits.enumerated() {
        let title = titleByPath[h.path].flatMap { $0.isEmpty ? nil : $0 } ?? h.path
        print(String(format: "%2d. %.4f  %@", i + 1, h.score, title))
        print("    \(h.path)")
    }

default:
    usage()
}
