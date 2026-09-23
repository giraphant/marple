# Marple CLI Absolute Paths

## Goal

Allow `marple-cli read` and `marple-cli open` to accept either the existing
workspace-relative document path or an absolute path to the same file inside
the configured Marple workspace.

## Design

Normalize paths in the app, where the configured workspace root is already
available. Relative paths keep their current representation. Absolute paths
are standardized, compared to the standardized workspace root by path
components, and converted back to the relative path used by the index.

An absolute path outside the workspace does not resolve and continues to
produce the CLI's existing `not_found` response. The index and wire protocol
remain relative-path based.

`read` normalizes before its index lookup. `open` normalizes inside the shared
`cliOpenDocument` entry point so both the live Unix-socket request and the
cold-start `marple://open` fallback behave identically. CLI help text describes
both accepted forms.

## Alternatives Rejected

- Reading Marple preferences in `marple-cli` would duplicate workspace
  discovery and would not cover alternate app instances cleanly.
- Adding absolute aliases to the index would introduce a second identity for
  every document and disturb existing relative-path invariants.

## Verification

- Existing relative-path `read` and `open` tests remain green.
- Vault-internal absolute paths work for both commands.
- Workspace-root and outside-workspace absolute paths are rejected.
- The rebuilt CLI is exercised against the running app with a real absolute
  vault path.
