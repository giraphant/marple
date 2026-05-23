import Testing
import Foundation
@testable import MarpleKit

@Suite struct TrashItemTests {
    @Test func testDecodesTrashListPayload() throws {
        let json = #"{"items":[{"name":"my-note.2026-05-23T10-00-00-000Z.md","originalBase":"my-note","ts":"2026-05-23T10-00-00-000Z","mtime":1716460800.0,"size":42}]}"#
        struct Wrapper: Decodable { let items: [TrashItem] }
        let items = try JSONDecoder().decode(Wrapper.self, from: Data(json.utf8)).items
        #expect(items.count == 1)
        #expect(items[0].name == "my-note.2026-05-23T10-00-00-000Z.md")
        #expect(items[0].originalBase == "my-note")
        #expect(items[0].ts == "2026-05-23T10-00-00-000Z")
        #expect(items[0].mtime == 1716460800.0)
        #expect(items[0].size == 42)
        #expect(items[0].id == items[0].name)
    }

    @Test func testDecodesNullOriginalBase() throws {
        let json = #"{"name":"weird.md","originalBase":null,"ts":null,"mtime":1.0,"size":0}"#
        let item = try JSONDecoder().decode(TrashItem.self, from: Data(json.utf8))
        #expect(item.originalBase == nil)
        #expect(item.ts == nil)
    }
}
