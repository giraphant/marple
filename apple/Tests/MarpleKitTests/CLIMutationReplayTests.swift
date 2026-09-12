import Foundation
import Testing
@testable import Marple
import MarpleKit

@MainActor @Suite struct CLIMutationReplayTests {
    @Test(arguments: ["age", "count", "bytes"])
    func absentRecoveryNeverExecutesAnotherWrite(_ eviction: String) {
        var now: TimeInterval = 0
        let cache = CLIMutationReplayCache(maxEntries: eviction == "count" ? 1 : 256,
                                          maxBytes: eviction == "bytes" ? 1 : 16 * 1024 * 1024,
                                          timeToLive: 1, now: { now })
        let key = UUID().uuidString
        let original = CLIRequest(method: "folders.create", title: "Keep")
        var calls = 0
        let perform = { calls += 1; return CLIResponse.success() }
        #expect(cache.respond(to: original.asMutation(requestID: key, retryOnly: false), perform: perform).ok)
        if eviction == "age" { now = 2 }
        if eviction == "count" {
            _ = cache.respond(to: original.asMutation(requestID: UUID().uuidString, retryOnly: false), perform: perform)
        }
        let before = calls
        let response = cache.respond(to: original.asMutation(requestID: key, retryOnly: true), perform: perform)
        #expect(response.error?.code == "request_unknown")
        #expect(calls == before)
    }

    @Test func dissolveReplaysOriginalSuccessAndValidationErrorsAreCached() {
        let cache = CLIMutationReplayCache()
        let original = CLIRequest(method: "folders.dissolve", id: UUID().uuidString)
        let key = UUID().uuidString
        var calls = 0
        let first = cache.respond(to: original.asMutation(requestID: key, retryOnly: false)) {
            calls += 1; return .success(CLIResponseData(tree: []))
        }
        let replay = cache.respond(to: original.asMutation(requestID: key, retryOnly: true)) {
            calls += 1; return .failure(code: "not_found", message: "already dissolved")
        }
        #expect(first.ok && replay.ok)
        #expect(calls == 1)
        #expect(replay.requestID == key)
        let errorKey = UUID().uuidString
        _ = cache.respond(to: original.asMutation(requestID: errorKey, retryOnly: false)) {
            .failure(code: "not_found", message: "missing folder")
        }
        let errorReplay = cache.respond(to: original.asMutation(requestID: errorKey, retryOnly: true)) { .success() }
        #expect(errorReplay.error?.code == "not_found")
    }

    @Test func invalidKeysAndUnsupportedOperationsDoNotExecute() {
        let cache = CLIMutationReplayCache()
        var calls = 0
        let perform = { calls += 1; return CLIResponse.success() }
        let invalid = CLIRequest(method: "folders.create", title: "Invalid").asMutation(requestID: "bad", retryOnly: false)
        #expect(cache.respond(to: invalid, perform: perform).error?.code == "bad_request")
        let read = CLIRequest(method: "tabs.list").asMutation(requestID: UUID().uuidString, retryOnly: false)
        #expect(cache.respond(to: read, perform: perform).error?.code == "bad_request")
        let absent = CLIRequest(method: "folders.create", title: "Unknown").asMutation(requestID: UUID().uuidString, retryOnly: true)
        #expect(cache.respond(to: absent, perform: perform).error?.code == "request_unknown")
        #expect(calls == 0)
    }
}
