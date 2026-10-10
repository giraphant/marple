import Foundation
import Observation
import MarpleKit

@Observable @MainActor
final class TermIndexController {
    let index: TermIndex
    private(set) var status: TermIndexStatus?
    private(set) var lastError: String?
    private(set) var isRunning = false
    @ObservationIgnored private var running: Task<TermIndexStatus, Error>?
    @ObservationIgnored private var pendingRefresh = false
    @ObservationIgnored private var pendingRebuild = false

    init(workspaceRoot: String) {
        index = TermIndex(workspaceRoot: workspaceRoot)
    }

    func scheduleRefresh() {
        Task { try? await refresh() }
    }

    /// Signals received during a scan collapse into one trailing pass. CLI and
    /// settings join the same task, including that pass, before reporting success.
    @discardableResult
    func refresh(rebuild: Bool = false) async throws -> TermIndexStatus {
        pendingRefresh = true
        pendingRebuild = pendingRebuild || rebuild
        if let running { return try await running.value }
        isRunning = true
        lastError = nil
        let task = Task { @MainActor in
            defer { self.running = nil; self.isRunning = false }
            do {
                if status == nil { status = try await index.status() }
                repeat {
                    let rebuild = pendingRebuild
                    pendingRefresh = false
                    pendingRebuild = false
                    status = try await index.refresh(rebuild: rebuild)
                } while pendingRefresh
                return status!
            } catch {
                lastError = String(describing: error)
                throw error
            }
        }
        running = task
        return try await task.value
    }
}
