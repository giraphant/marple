import Foundation
import MarpleKit

// Heal damaged YAML frontmatter across a vault. Two distinct fixes:
//   1. Strip Ulysses-bite damage from list-shaped fields:
//      `themes: [a, b](#)` → `themes: [a, b]`
//   2. Upgrade flow arrays to block lists for `themes` / `author` / `authors`
//      (SPEC §5.2 — Ulysses-safe). Empty optional list values are dropped.
//
//   swift run heal-frontmatter --vault <path> --dry-run
//   swift run heal-frontmatter --vault <path> --apply

setvbuf(stdout, nil, _IONBF, 0)

private let LIST_KEYS = ["themes", "author", "authors"]

private func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

private func parseCLI() -> (vault: URL, apply: Bool) {
    var vault: String?
    var dryRun = false
    var apply = false
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--vault":
            i += 1
            guard i < args.count else { die("--vault requires a path") }
            vault = args[i]
        case "--dry-run":
            dryRun = true
        case "--apply":
            apply = true
        case "-h", "--help":
            print("""
            usage:
              heal-frontmatter --vault <path> --dry-run
              heal-frontmatter --vault <path> --apply

            Heals damaged YAML frontmatter across a vault:
              - Strips Ulysses-bite damage on themes/author/authors
              - Upgrades flow arrays to block lists (SPEC §5.2)
              - Drops empty list fields
            """)
            exit(0)
        default:
            die("unknown arg: \(args[i])")
        }
        i += 1
    }
    guard let v = vault else { die("--vault required") }
    guard dryRun != apply else { die("must specify exactly one of --dry-run or --apply") }
    return (URL(fileURLWithPath: v), apply)
}

private func upgradeListFields(_ raw: String) -> String {
    let (rawFm, _) = Frontmatter.split(raw)
    guard let rawFm = rawFm else { return raw }
    let pairs = YamlFrontmatter.parseMapping(rawFm)

    var result = raw
    for key in LIST_KEYS {
        guard let value = pairs.first(where: { $0.0 == key })?.1 else { continue }
        switch value {
        case .sequence(let items):
            let strings = items.compactMap { textValue($0) }.filter { !$0.isEmpty }
            if strings.isEmpty {
                result = FrontmatterPatch.removeKey(result, key: key)
            } else {
                result = FrontmatterPatch.setSequence(result, key: key, values: strings)
            }
        case .null:
            result = FrontmatterPatch.removeKey(result, key: key)
        default:
            // Scalar legacy form (e.g. `author: Foo`) is QUA-109's concern,
            // not QUA-108's. Heal-frontmatter focuses on list-shape damage.
            continue
        }
    }
    return result
}

private func heal(_ raw: String) -> String {
    upgradeListFields(FrontmatterSanitizer.sanitize(raw))
}

let (vault, apply) = parseCLI()

guard let enumerator = FileManager.default.enumerator(
    at: vault,
    includingPropertiesForKeys: [.isRegularFileKey]
) else {
    die("cannot enumerate \(vault.path)")
}

var totalFiles = 0
var changedFiles = 0

while let next = enumerator.nextObject() as? URL {
    guard next.pathExtension == "md" else { continue }
    totalFiles += 1

    guard let text = try? String(contentsOf: next, encoding: .utf8) else { continue }
    let healed = heal(text)
    if healed == text { continue }

    changedFiles += 1
    print("changed: \(next.path)")
    if apply {
        do {
            try healed.write(to: next, atomically: true, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(Data("write failed for \(next.path): \(error)\n".utf8))
        }
    }
}

print("---")
print("scanned: \(totalFiles) .md files")
print("changed: \(changedFiles)")
print(apply ? "mode: APPLIED" : "mode: DRY-RUN — re-run with --apply to write")
