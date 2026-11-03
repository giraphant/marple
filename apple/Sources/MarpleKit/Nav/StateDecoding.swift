import Foundation

/// Lenient decoding for persisted navigation state. Builds from different branches
/// write slightly different schemas (an extra sort field, a new pane), and one
/// unreadable tab used to fail the whole blob — which the app then overwrote with
/// an empty session. Undecodable items are skipped and recorded here instead, so
/// the store can back up the original bytes before the next save drops them.
final class StateDecodeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var errors: [String] { lock.withLock { recorded } }

    func record(_ error: Error) {
        let text = String(describing: error)
        lock.withLock { recorded.append(text) }
    }
}

extension CodingUserInfoKey {
    static let stateDecodeLog = CodingUserInfoKey(rawValue: "marple.stateDecodeLog")!
}

extension Decoder {
    func recordDropped(_ error: Error) {
        NSLog("[marple] persisted state: skipped undecodable item: %@", String(describing: error))
        (userInfo[.stateDecodeLog] as? StateDecodeLog)?.record(error)
    }
}

/// Decodes an array element by element, skipping elements that fail. `indexMap`
/// maps original indices to kept ones, so index references (tree leaves,
/// `activeIndex`) can be remapped rather than shifting onto the wrong tab.
struct LossyArray<Element: Decodable>: Decodable {
    var values: [Element] = []
    var indexMap: [Int: Int] = [:]
    var droppedAny = false

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            let index = container.currentIndex
            // superDecoder() advances past the element even if decoding it fails.
            let element = try container.superDecoder()
            do {
                values.append(try Element(from: element))
                indexMap[index] = values.count - 1
            } catch {
                droppedAny = true
                decoder.recordDropped(error)
            }
        }
    }
}

extension KeyedDecodingContainer {
    /// An optional value that is treated as absent (and recorded) when unreadable.
    func lenient<T: Decodable>(_ type: T.Type, forKey key: Key, in decoder: Decoder) -> T? {
        do { return try decodeIfPresent(type, forKey: key) } catch {
            decoder.recordDropped(error)
            return nil
        }
    }

    func lossyArray<T: Decodable>(_ type: T.Type, forKey key: Key, in decoder: Decoder) -> LossyArray<T>? {
        lenient(LossyArray<T>.self, forKey: key, in: decoder)
    }
}

extension WorkspaceTreeSnapshot {
    /// Re-point tab leaves after tabs were dropped; leaves of dropped tabs go away.
    func remappingTabs(_ indexMap: [Int: Int]) -> WorkspaceTreeSnapshot {
        func remap(_ nodes: [Node]) -> [Node] {
            nodes.compactMap { node in
                switch node {
                case .tab(let index):
                    return indexMap[index].map { .tab($0) }
                case .group(var group):
                    group.children = remap(group.children)
                    return .group(group)
                }
            }
        }
        return WorkspaceTreeSnapshot(roots: remap(roots))
    }
}
