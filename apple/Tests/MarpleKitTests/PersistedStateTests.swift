import Testing
import Foundation
@testable import MarpleKit

@Suite struct DomainCodableTests {
    @Test func paneRoundTrips() throws {
        let cases: [Pane] = [.type(.paperAnalysis), .type(.other("weird")),
                             .themesIndex, .theme("现象学"), .trash]
        for p in cases {
            let data = try JSONEncoder().encode(p)
            #expect(try JSONDecoder().decode(Pane.self, from: data) == p)
        }
    }

    @Test func sortAndFilterClausesRoundTrip() throws {
        let sorts = [SortClause(field: .rating, dir: .desc), SortClause(field: .title, dir: .asc)]
        let filters = [FilterClause(id: "a", field: .year, op: .gte, value: "2000"),
                       FilterClause(id: "b", field: .haspdf, op: .yes, value: "")]
        let sd = try JSONEncoder().encode(sorts)
        let fd = try JSONEncoder().encode(filters)
        #expect(try JSONDecoder().decode([SortClause].self, from: sd) == sorts)
        #expect(try JSONDecoder().decode([FilterClause].self, from: fd) == filters)
        #expect(try JSONDecoder().decode(FilterMatch.self,
                from: JSONEncoder().encode(FilterMatch.any)) == .any)
    }

    @Test func navLocationRoundTrips() throws {
        let loc = NavLocation(pane: .theme("X"), openPath: "vault/a.md")
        let data = try JSONEncoder().encode(loc)
        #expect(try JSONDecoder().decode(NavLocation.self, from: data) == loc)
    }
}
