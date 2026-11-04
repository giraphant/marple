import Foundation
import Testing
@testable import Marple

struct SidebarChildDiffTests {
    @Test(arguments: [80, 500, 5000])
    func wideSiblingLists(count: Int) {
        let old = Array(0..<count)
        let rotated = Array(old.dropFirst()) + [0]
        let move = SidebarChildDiff(from: old, to: rotated)
        #expect(move.operationCount == 1)
        #expect(move.move?.from == 0)
        #expect(move.move?.to == count - 1)
        let reversed = Array(old.reversed())
        let diff = SidebarChildDiff(from: old, to: reversed)
        #expect(apply(diff, from: old, to: reversed) == reversed)
        #expect(diff.removals.count == count - 1)
    }

    @Test func mixedInsertionsRemovalsAndPermutations() {
        var seed: UInt64 = 42
        func next() -> UInt64 {
            seed = seed &* 6364136223846793005 &+ 1
            return seed
        }
        for _ in 0..<1000 {
            let old = (0..<32).filter { _ in next() % 3 != 0 }
            var new = (0..<40).filter { _ in next() % 4 != 0 }
            for index in new.indices.dropFirst().reversed() {
                new.swapAt(index, Int(next() % UInt64(index + 1)))
            }
            let diff = SidebarChildDiff(from: old, to: new)
            #expect(apply(diff, from: old, to: new) == new)
        }
    }

    private func apply(_ diff: SidebarChildDiff, from old: [Int], to new: [Int]) -> [Int] {
        var result = old.enumerated().filter { !diff.removals.contains($0.offset) }.map(\.element)
        for index in diff.insertions { result.insert(new[index], at: index) }
        return result
    }
}
