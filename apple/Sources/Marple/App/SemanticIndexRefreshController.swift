import Foundation
import Combine
import MarpleKit
import MarpleEmbeddings

@MainActor enum ActiveSemanticIndex {
    static let didChangeNotification = Notification.Name("marple.activeSemanticIndex.didChange")
    static var controller: SemanticIndexRefreshController? {
        didSet { NotificationCenter.default.post(name: didChangeNotification, object: controller) }
    }
}

@MainActor
final class SemanticIndexRefreshController: ObservableObject, @unchecked Sendable {
    private let workspaceRoot: String
    private let marpleDir: URL

    @Published private(set) var isRunning = false
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    struct ExistingIndex: Equatable {
        let model: String
        let dimension: Int
        let count: Int
        let updatedAt: Date?
    }

    @Published private(set) var lastResult: SemanticBuildResult?
    @Published private(set) var lastError: String?
    @Published private(set) var lastCompletedAt: Date?
    @Published private(set) var existingIndex: ExistingIndex?

    init(workspaceRoot: String, marpleDir: URL) {
        self.workspaceRoot = workspaceRoot
        self.marpleDir = marpleDir
        refreshExistingIndex()
    }

    func refreshExistingIndex() {
        existingIndex = Self.loadExistingIndex(marpleDir: marpleDir)
    }

    func refreshNow(model: AppModel?) {
        guard !isRunning else { return }
        guard let model else {
            lastError = "主窗口尚未就绪。"
            return
        }
        let entries = model.entries
        guard !entries.isEmpty else {
            lastError = "索引尚未载入，稍后再试。"
            model.flash(lastError!, symbol: "exclamationmark.triangle.fill")
            return
        }

        isRunning = true
        done = 0
        total = 0
        lastError = nil

        let workspaceRoot = self.workspaceRoot
        let marpleDir = self.marpleDir

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let docs = SemanticDocumentBuilder.docs(workspaceRoot: workspaceRoot, entries: entries)
                    let embedder = try await MLXTextEmbedder(modelId: SemanticIndexDefaults.modelID)
                    return try await SemanticIndexer(embedder: embedder).build(
                        dir: marpleDir,
                        model: SemanticIndexDefaults.modelID,
                        docs: docs,
                        batchSize: SemanticIndexDefaults.batchSize,
                        checkpointEvery: SemanticIndexDefaults.checkpointEvery
                    ) { done, total in
                        Task { @MainActor in
                            guard self.isRunning else { return }
                            self.done = done
                            self.total = total
                        }
                    }
                }.value
                lastResult = result
                lastCompletedAt = Date()
                refreshExistingIndex()
                done = result.total
                total = result.total
                model.installSemanticBackend(MLXSemanticBackend(dir: marpleDir))
                model.flash("语义索引已刷新：嵌入 \(result.embedded)，复用 \(result.reused)，共 \(result.total)。", symbol: "sparkles")
                print("[marple] semantic index refreshed: embedded \(result.embedded), reused \(result.reused), total \(result.total)")
            } catch {
                lastError = "语义索引刷新失败，请查看日志。"
                model.flash(lastError!, symbol: "exclamationmark.triangle.fill")
                print("[marple] semantic index refresh FAILED: \(error)")
            }
            isRunning = false
        }
    }

    private static func loadExistingIndex(marpleDir: URL) -> ExistingIndex? {
        do {
            guard let loaded = try VectorIndexIO.read(dir: marpleDir) else { return nil }
            let manifestURL = VectorIndexIO.manifestURL(dir: marpleDir)
            let updatedAt = try? FileManager.default
                .attributesOfItem(atPath: manifestURL.path)[.modificationDate] as? Date
            return ExistingIndex(
                model: loaded.manifest.model,
                dimension: loaded.manifest.dim,
                count: loaded.manifest.rows.count,
                updatedAt: updatedAt)
        } catch {
            print("[marple] semantic index status read FAILED: \(error)")
            return nil
        }
    }
}
