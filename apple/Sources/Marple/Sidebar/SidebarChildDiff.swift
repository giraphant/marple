import Foundation

/// A longest increasing subsequence keeps the largest possible set of siblings
/// in place. Unlike repeated firstIndex scans, planning stays O(n log n), even
/// for a reversed list. IDs must be unique within each sibling list.
struct SidebarChildDiff {
    let removals: IndexSet
    let insertions: IndexSet
    let move: (from: Int, to: Int)?

    var operationCount: Int { move == nil ? removals.count + insertions.count : 1 }

    init<ID: Hashable>(from old: [ID], to new: [ID]) {
        let oldIndices = Dictionary(uniqueKeysWithValues: old.enumerated().map { ($1, $0) })
        let matches = new.compactMap { id in oldIndices[id].map { (id, $0) } }
        var tails: [Int] = []
        var predecessors = Array(repeating: -1, count: matches.count)
        for index in matches.indices {
            var lower = 0
            var upper = tails.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if matches[tails[middle]].1 < matches[index].1 { lower = middle + 1 }
                else { upper = middle }
            }
            if lower > 0 { predecessors[index] = tails[lower - 1] }
            if lower == tails.count { tails.append(index) }
            else { tails[lower] = index }
        }
        var kept = Set<ID>()
        var cursor = tails.last ?? -1
        while cursor >= 0 {
            kept.insert(matches[cursor].0)
            cursor = predecessors[cursor]
        }
        removals = IndexSet(old.indices.filter { !kept.contains(old[$0]) })
        insertions = IndexSet(new.indices.filter { !kept.contains(new[$0]) })
        if removals.count == 1, insertions.count == 1,
           let from = removals.first, let to = insertions.first, old[from] == new[to] {
            move = (from, to)
        } else {
            move = nil
        }
    }
}
