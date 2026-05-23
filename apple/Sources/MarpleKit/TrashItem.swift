import Foundation

/// One soft-deleted file in `vault/notes/.trash/`, as returned by `GET /api/trash`.
public struct TrashItem: Sendable, Equatable, Identifiable, Decodable {
    public let name: String          // "<base>.<iso-ts>.md"
    public let originalBase: String?
    public let ts: String?
    public let mtime: Double
    public let size: Int
    public var id: String { name }

    public init(name: String, originalBase: String?, ts: String?, mtime: Double, size: Int) {
        self.name = name
        self.originalBase = originalBase
        self.ts = ts
        self.mtime = mtime
        self.size = size
    }
}
