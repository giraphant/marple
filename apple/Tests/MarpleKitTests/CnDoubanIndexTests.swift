import Testing
import Foundation
@testable import MarpleKit

@Suite struct CnDoubanIndexTests {

    /// Write `json` to `<tmp>/.quasi/localise/cndouban.json` and load it.
    private func loadFixture(_ json: String) throws -> CnDoubanIndex? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cndouban-\(UUID().uuidString)")
        let dir = root.appendingPathComponent(".quasi/localise")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.write(to: dir.appendingPathComponent("cndouban.json"), atomically: true, encoding: .utf8)
        return CnDoubanIndex.load(workspaceRoot: root.path)
    }

    @Test func absentSidecarLoadsNil() {
        #expect(CnDoubanIndex.load(workspaceRoot: "/no/such/workspace") == nil)
        #expect(CnDoubanIndex.load(workspaceRoot: "") == nil)
    }

    @Test func resolvesViaCndoubanIdsAndByDoubanId() throws {
        // status=found, empty books[], edition referenced by cndouban_ids; the
        // rich title lives in by_douban_id and the URL is synthesised from the id.
        let idx = try #require(try loadFixture("""
        {"version":1,
         "by_isbn":{"9780822373377":{"status":"found","selected_id":null,
                                     "cndouban_ids":["36494081"],"books":[]}},
         "by_douban_id":{"36494081":{"douban_id":"36494081","title":"过一种女性主义的生活"}}}
        """))
        let t = try #require(idx.translation(forISBN: "978-0-8223-7337-7"))  // dashed → matches
        #expect(t.titleCn == "过一种女性主义的生活")
        #expect(t.doubanURL == "https://book.douban.com/subject/36494081/")
    }

    @Test func selectedIdWinsOverOtherCandidates() throws {
        let idx = try #require(try loadFixture("""
        {"by_isbn":{"111":{"status":"found","selected_id":"222",
                           "cndouban_ids":["999"],
                           "books":[{"douban_id":"222","title":"选定版","douban_url":"https://book.douban.com/subject/222/"}]}},
         "by_douban_id":{"999":{"title":"未选版"}}}
        """))
        let t = try #require(idx.translation(forISBN: "111"))
        #expect(t.titleCn == "选定版")
        #expect(t.doubanURL == "https://book.douban.com/subject/222/")
    }

    @Test func nonNumericManualIdHasNoURL() throws {
        let idx = try #require(try loadFixture("""
        {"by_isbn":{"111":{"status":"found","cndouban_ids":["manual-ong"],"books":[]}},
         "by_douban_id":{"manual-ong":{"title":"口语文化与书面文化"}}}
        """))
        let t = try #require(idx.translation(forISBN: "111"))
        #expect(t.titleCn == "口语文化与书面文化")
        #expect(t.doubanURL == nil)
    }

    @Test func noneAndErrorStatusesAreOmitted() throws {
        let idx = try #require(try loadFixture("""
        {"by_isbn":{
           "111":{"status":"none","cndouban_ids":[],"books":[]},
           "222":{"status":"error","cndouban_ids":["1"],"books":[]}},
         "by_douban_id":{"1":{"title":"x"}}}
        """))
        #expect(idx.translation(forISBN: "111") == nil)
        #expect(idx.translation(forISBN: "222") == nil)
    }
}
