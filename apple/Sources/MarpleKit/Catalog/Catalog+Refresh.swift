import Foundation

// Unified refresh authority (QUA-218 PR3a Task 7)：refresh / refreshJoining / isStale /
// beginStandalonePass。The `authority` + `pass` STORED props live in Catalog.swift; the
// methods here drive the coalescing single-flight + per-pass generation. Split out of
// Catalog.swift (QUA-218 PR3a Task 8); method bodies are byte-identical to the original.
extension Catalog {
    /// 唯一刷新入口（watcher/boot）。合流单飞（保留 OOM bound）+ 每 pass bump 一次。
    /// body = 壳的 reconcile→loadIndex 闭包；body 内用 `isStale(myPass)` 在每个挂起点
    /// 后自检，陈旧即丢弃发布。
    public func refresh(_ body: (_ myPass: Int) async -> Void) async {
        guard await authority.tryBegin() else { return }
        repeat {
            pass &+= 1
            let myPass = pass
            await body(myPass)
        } while await authority.finishOrRerun()
    }

    /// CLI join 路径（refreshJoining）：busy 时 beginOrJoin 挂起等一次新 trailing pass
    /// 完成（返回 false，无事可做）；idle 时获取门并自跑（返回 true）。复刻旧
    /// cliRefreshIndex 的 `if beginOrJoin() { repeat refreshChain() while finishOrRerun() }`。
    public func refreshJoining(_ body: (_ myPass: Int) async -> Void) async {
        if await authority.beginOrJoin() {
            repeat {
                pass &+= 1
                let myPass = pass
                await body(myPass)
            } while await authority.finishOrRerun()
        }
    }

    /// True when a newer pass has begun since `myPass` was captured — a loadIndex
    /// running under `myPass` should then drop its publish (旧 loadIndexGeneration
    /// 守卫语义)。
    public func isStale(_ myPass: Int) -> Bool { pass != myPass }

    /// 独立刷新入口（restoreTrash、boot 首次 loadIndex、测试）直接调 loadIndex 而不
    /// 经 refresh 单飞时，仍需一个有效 pass：bump 并返回。等价于旧 loadIndexGeneration
    /// 在 loadIndex 入口的 `&+= 1`，让两个并发裸 loadIndex 各持不同 pass、旧者自检陈旧。
    ///
    /// Does NOT touch the single-flight authority — it ONLY advances the staleness
    /// generation; never call it to trigger a refresh (use refresh/refreshJoining).
    public func beginStandalonePass() -> Int {
        pass &+= 1
        return pass
    }
}
