import Foundation

extension Array {
    /// Bounds-checked index — nil instead of a trap when the collection view
    /// asks about an index that a concurrent reload just removed.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
