# Marple CLI for AI Agents — Design (QUA-107)

**Goal:** Give AI agents a small, safe way to search, read, and open concrete Marple documents through the running app.

**Why CLI, not direct file/DB access:** The CLI is a thin client; every operation flows over a Unix socket to Marple, which executes it through its existing `AppModel` + MarpleKit links. The GUI stays the single source of truth.

## Architecture

```
┌────────────┐  one JSON line over   ┌─────────────────────────┐
│ marple-cli │ ────────────────────▶ │  Marple.app (running)   │
│  (binary)  │  Unix domain socket   │                         │
│            │ ◀──────────────────── │  CLIServer ─▶ AppModel  │
└────────────┘  one JSON line back   │            (existing)   │
                                     └─────────────────────────┘
```

- Server binds `~/Library/Application Support/Marple/cli.sock` (mode 0600). It is off by default and opt-in via Settings.
- Each connection handles one `CLIRequest` line and returns one `CLIResponse` line.
- `marple-cli open <path>` falls back to `open marple://open?path=...` when the socket is unreachable, so a closed app can launch and open the requested document.

## Public Scope

| command | method | behavior |
|---|---|---|
| `marple-cli search <query> [--limit]` | `search` | Full-text search through the running Marple index. |
| `marple-cli read <path>` | `read` | Returns the entry digest plus raw frontmatter and body. |
| `marple-cli open <path>` | `open` | Opens a concrete document into the left-side Pages workspace; activates an existing page if already open. |
| `marple-cli ping` | `ping` | Liveness probe for scripts and tests. |

There is no public theme/list navigation layer in QUA-107. Themes are metadata and query terms, not GUI actions. Metadata/frontmatter editing is deferred to QUA-97 and should be designed as whole-frontmatter editing rather than narrow `tag` commands.

## Wire Protocol

NDJSON over the socket. Shared types live in `MarpleKit/CLI/CLIProtocol.swift` so client and server use the same Codable definitions.

```jsonc
// Request
{"method": "search", "query": "phenomenology", "limit": 20}
{"method": "read", "path": "papers/foo.md"}
{"method": "open", "path": "papers/foo.md"}
{"method": "ping"}

// Response
{"ok": true,  "data": {...}}
{"ok": false, "error": {"code": "marple_not_running", "message": "..."}}
```

Error codes: `marple_not_running`, `bad_request`, `not_found`, `internal_error`.

## Open Semantics

`open <path>` always targets a concrete document page:

1. Reject paths not present in the live index with `not_found`.
2. If the document already has a page in `workspace.tabs`, select that page.
3. Otherwise create a new document page in the Pages workspace and activate it.

It does not switch the middle browse list to a theme filter, and it does not expose separate `open page`, `open tab`, or `open entry` subcommands.

## File Layout

```
apple/Sources/
├── MarpleKit/CLI/
│   └── CLIProtocol.swift          # Codable Request/Response types + socket path
├── Marple/CLI/
│   ├── AppModel+CLI.swift         # @MainActor methods called by handlers
│   ├── CLIHandlers.swift          # method dispatch → AppModel surface
│   └── CLIServer.swift            # socket listener + per-connection IO
└── marple-cli/
    └── main.swift                 # client: argparse → socket round-trip → JSON out
```

## Security and Lifecycle

- Socket mode `0600`, located in the user's `~/Library/Application Support`.
- No authentication token; the OS user is the trust boundary.
- Stale socket from prior crash is `unlink()`-ed at start; `stop()` removes it cleanly.
- Requests have a 1 MB soft cap and accepted sockets use IO timeouts.
- `AppState.boot` constructs `CLIServer` after `AppModel` is ready and honors the `marple.cliServerEnabled` setting.

## Out of Scope

- Metadata/frontmatter edits, including theme/tag mutation. Deferred to QUA-97.
- Body edit, create-note, delete, and trash actions.
- GUI state introspection beyond opening a concrete document page.
- Semantic/vector search; that remains separate from this CLI pass.
- NDJSON streaming for large result sets.

## Cross-References

- QUA-107 issue thread for the narrowed search/read/open decision.
- QUA-97 for future metadata/frontmatter editing design.
- `apple/Sources/semantic-tool/` as the existing standalone CLI target pattern.
