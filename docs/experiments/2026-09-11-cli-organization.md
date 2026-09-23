# CLI organization validation and ablations

Date: 2026-09-11. Base revision: `b4f6852`.

## Scope

The current Space's sidebar tree is exposed through `tabs list`. The CLI can
rename/reset tab titles, move ordered batches, create folders containing tabs
and folders, create subfolders, rename/move folders, and dissolve folders while
preserving their children. Commands and positioning semantics are documented
in the root README.

Implementation uses the existing `Workspace` tree operations. One validated
copy is committed through `AppModel`, preserving app persistence and undo.
Invalid inputs cannot publish partial mutations. Moving into the fixed section
pins tabs; moving beside temporary tabs unpins them.

The reference review used the local clone of NetNewsWire at
`/tmp/marple-reference-repos/NetNewsWire`, specifically
`Mac/Scripting/Folder+Scriptability.swift` and
`Mac/MainWindow/Sidebar/SidebarOutlineDataSource.swift`: scriptable IDs and
model-level folder operations are shared with the UI. Marple's existing
recursive Workspace implementation supplies nesting; NetNewsWire's inspected
scripting implementation does not support nested folders.

## Baseline and review regression

Before implementation, all 10 new behavior tests failed with 16 assertion
issues, including `unknown method: tabs.rename` and missing folder creation.
After implementation those 10 tests passed.

Independent review identified an inherited undo bug: switching from Space A
to Space B before undo restored A's snapshot into B. The new regression
reproduced both failures: A remained renamed and B lost its folder. Undo now
captures the originating Space ID and keeps it for redo. Additional tests
cover unpinning when moving beside temporary tabs, undoing that move, and
distinguishing a pinned tab's identity path from its current reading path.

Final verification also reproduced SIGPIPE in the existing early-disconnect
test, in both parallel and serial runs. A minimal local socket reproduction
confirmed that setting `SO_NOSIGPIPE` after the peer closes can fail with
`EINVAL`. The server ignored that failure and its subsequent response write
could terminate the process. `writeResponse` now calls
`send(..., MSG_NOSIGNAL)`, retaining its partial-send loop while suppressing the
signal on each send. Independent review confirmed the fix, and the original
early-disconnect regression passed 20 consecutive runs afterward. Those logs
are in `/tmp/marple-cli-disconnect-repeat/`.

## Controlled ablations

Each run used the same 13 `CLIOrganizationTests`. Only the stated mechanism was
changed, the variant was rebuilt, and the complete source file was restored
before the next variant. A detected variant requires actual test assertion
failures, not compiler errors or test-runner crashes.

| Variant | Deliberate change | Failing tests | Assertion issues |
| --- | --- | ---: | ---: |
| Full baseline | None | 0 | 0 |
| Without pin transition | Remove `workspace.togglePin(tab.id)` from `cliMove` | 6 | 19 |
| Without input order | In `cliItems`, select in existing tree preorder instead of request order | 4 | 6 |
| Without cycle validation | Disable the descendant check in `cliValidateDestination` | 1 | 10 |
| Without CLI undo | Remove undo registration from `cliApplyWorkspace` | 3 | 7 |
| Without undo Space binding | Restore using the current Space rather than the captured Space | 1 | 2 |
| Restored implementation | Restore all original source bytes | 0 | 0 |

The cycle variant is caught by `invalidRequestsLeaveWholeWorkspaceUnchanged`.
The Space variant is caught by `undoAfterSwitchingSpacesEditsOnlyOriginalSpace`.
Order variants are caught by tab and folder batch ordering and nested-folder
tests. Pin and undo variants are also caught by the restart/undo test.

All five variants were detected. This establishes sensitivity to these five
specific failures, not exhaustive correctness for every possible mutation.
Raw experiment records for this run are in `/tmp/marple-cli-ablation/`, with
per-variant logs and `results.json`; the temporary driver is
`/tmp/marple-cli-ablation.py`.

## Final verification

- 127 tests across 8 relevant CLI, navigation, restoration, and sidebar suites.
- 20 consecutive passes of the previously intermittent early-disconnect test.
- 16 executable CLI socket smoke cases, covering every new command, ordered
  multi-item arguments, Chinese titles, reset, destinations, and JSON/nonzero
  error propagation.
- The server integration test exercises create, rename, list, and rejected
  self-nesting through a real Unix socket and the real `AppModel`.
- The CLI smoke server uses a temporary `CFFIXED_USER_HOME`; a ping verifies
  isolation before any mutation request is sent. It checks argument-to-wire
  mapping; app behavior is tested by the Swift suites, not by the smoke stub.

The installed Xcode 26.6 toolchain (Swift 6.3.3) was used. The machine's default
Command Line Tools toolchain selects SDK 27, which changes existing renderer
override signatures; its new default build engine also requires unavailable
resource tools. No unrelated renderer or package changes were made.

Re-run the final suites from `apple/`:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk \
xcrun swift test --disable-sandbox \
  -Xswiftc -F \
  -Xswiftc /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks \
  --filter 'CLIOrganizationTests|CLIServerTests|WorkspaceTests|NestedTabGroupTests|BatchTabActionsTests|WorkspaceRestoreTests|SidebarUndoTests|SidebarPageSectionTests'

python3 Tests/CLI/organization_smoke.py
```

To reproduce one ablation, apply the single change from the table, run the
same Swift command with `--filter CLIOrganizationTests`, confirm assertion
failures, restore that change, and rerun the full command above.
