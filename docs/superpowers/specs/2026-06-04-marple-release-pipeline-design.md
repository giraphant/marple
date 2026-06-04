# Marple Versioning + Release Pipeline — Design

Date: 2026-06-04
Status: Approved for planning
Reference: `giraphant/dousha` (mature local-Makefile release flow)

## Goal

Give the native macOS app (`apple/`) a real versioning scheme and an end-to-end
release/assembly pipeline, modeled on dousha. Success = a single
`make release VERSION=x.y.z` produces a **signed + notarized** DMG, publishes a
GitHub Release, tags the commit, and bumps a Homebrew cask — and the resulting
build launches and runs 深度 (semantic) search on a clean machine.

## Decisions (locked)

| Fork | Decision |
| --- | --- |
| Distribution | Mirror dousha fully: Developer ID sign + hardened runtime → notarized DMG on GitHub Releases → Homebrew cask in `giraphant/homebrew-tap`. |
| Release runner | Local Mac. Signing cert + notary profile stay in gitignored `apple/Makefile.local`. No GitHub Actions. |
| Start version | `v0.1.0` (pre-1.0; the hardcoded `1.0` in `build-app.sh` was never a real release). |
| CLI in cask | Cask installs `Marple.app` **and** symlinks the bundled `marple-cli` onto PATH (`binary` stanza). |
| Apple account | Reuse dousha's Developer ID + notarytool keychain profile. No new Apple setup. |

## Scope

In scope: the native macOS app under `apple/` only.
Out of scope: the web/`legacy/` app; GitHub Actions / CI automation.

## Architecture

dousha drives everything from one `Makefile`. marple already has
`apple/build-app.sh` carrying the hard assembly logic (MLX `default.metallib`
bootstrapping, dual-binary bundling, `.icns` generation, inline Info.plist).
We keep that as the assembly core and add a thin orchestration layer.

- **New `apple/Makefile`** — orchestration. Targets mirror dousha:
  `build` `run` `install` `dist` `notarize` `release` `update-cask` `clean`.
- **`apple/build-app.sh` stays the assembly core**, parametrized via env:
  - `CONFIG` — `debug` (default, dev) or `release`. Selects `swift build` vs
    `swift build -c release` and the matching `.build/.../{debug,release}` path.
  - `VERSION` — read from `apple/VERSION` by the Makefile and passed in; injected
    into the generated Info.plist. Removes the hardcoded `VERSION="1.0"`.
  - `SIGN` — when set, codesign the bundle with Developer ID + hardened runtime
    (see Signing). When unset (dev), keep current behavior (no signing).
  - Existing dev flow (`./build-app.sh` → debug bundle + PATH symlink) is
    unchanged when these are unset.
- **New `apple/Makefile.local`** (gitignored) — `DEVELOPER_ID_IDENTITY`,
  `NOTARY_PROFILE`, reused from dousha. `-include`d by the Makefile; ad-hoc
  fallback if absent (dev installs).
- **New `apple/Resources/Marple.entitlements`** — hardened-runtime entitlements.

## Components

### 1. Versioning — single source of truth
- **`apple/VERSION`** — one line, `0.1.0`. The source of truth for the marketing
  version.
- `CFBundleShortVersionString` ← `apple/VERSION` (injected by `build-app.sh`).
- `CFBundleVersion` (build number) ← `git rev-list --count HEAD` — monotonic,
  required so notarytool accepts repeat submissions of the same marketing
  version.
- Git tag `vX.Y.Z` created/pushed by `make release` (via `gh release create`,
  as dousha does).

### 2. Signing — nested-binary wrinkle (differs from dousha)
dousha has one Mach-O and uses `--deep`. marple bundles **two** executables
(`Marple`, `marple-cli`) plus the `mlx.metallib` resource. `--deep` is deprecated
and unreliable for notarization. Sign inner-out, each with `--options runtime`:
1. `codesign` `marple-cli`
2. `codesign` `Marple`
3. `codesign` the `.app` wrapper (with `--entitlements Resources/Marple.entitlements`)

The metallib is a resource, not code — no separate signing.

### 3. MLX + hardened runtime — notarization risk to verify (marple-only)
MLX compiles/loads Metal at runtime. Hardened runtime may reject it without
relaxed entitlements. Start with, in `Marple.entitlements`:
- `com.apple.security.cs.allow-jit` = true
- `com.apple.security.cs.disable-library-validation` = true

**Success criterion is behavioral, not just "notarytool accepted":** the
notarized DMG must install, launch, and successfully run a 深度 (semantic) search
query on a clean machine. If MLX still fails, narrow/adjust entitlements until it
runs. Do not declare the release flow done on a green notarytool alone.

### 4. DMG packaging (same as dousha)
`hdiutil create -format UDZO`, `/Applications` symlink in the staging dir, then
`codesign` the DMG with the Developer ID + `--timestamp`.

### 5. Notarize + staple (same as dousha)
`xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait`
then `xcrun stapler staple "$DMG"`.

### 6. Publish (same as dousha)
`gh release create "v$VERSION" "$DMG" --title "v$VERSION" --generate-notes`.
Guards before publishing (mirror dousha):
- `apple/VERSION` must equal the `VERSION=` argument.
- Working tree must be clean (version bump already committed).

### 7. Homebrew cask — ship the CLI too (differs from dousha)
- New cask `Casks/marple.rb` in `giraphant/homebrew-tap` →
  `brew install --cask giraphant/tap/marple`.
- `app "Marple.app"` **plus** a `binary` stanza symlinking
  `Marple.app/Contents/MacOS/marple-cli` onto Homebrew's PATH, so cask users get
  the CLI without running `build-app.sh`.
- `update-cask` target clones the tap, patches only `version` + `sha256`
  (sha256 of the DMG), pushes. Idempotent (no-op if already current), as dousha.

## Release flow (end state)

```
# 1. bump apple/VERSION to 0.1.0, commit
# 2. one command:
make release VERSION=0.1.0
#   guard: VERSION matches apple/VERSION, working tree clean
#   → build-app.sh CONFIG=release SIGN=1 VERSION=0.1.0  (build + assemble + sign)
#   → dist   (DMG + sign DMG)
#   → notarize (submit --wait + staple)
#   → gh release create v0.1.0 <dmg> --generate-notes   (tags HEAD)
#   → update-cask VERSION=0.1.0   (bump giraphant/homebrew-tap)
```

Dev flow is unchanged: `./build-app.sh` (debug, ad-hoc, PATH symlink) and
`make build` / `make install`.

## Testing / verification

1. `make build` (debug) still produces a working dev bundle + PATH symlink — no
   regression to the existing flow.
2. `make dist` produces a signed DMG; `codesign --verify --deep --strict` and
   `spctl -a -t open --context context:primary-signature` pass.
3. `make notarize` → notarytool returns `Accepted`; `stapler validate` passes.
4. **Behavioral gate:** install the notarized DMG on a clean machine (or fresh
   user), launch, and run a 深度 semantic query successfully — confirms MLX runs
   under hardened runtime.
5. `make update-cask` patches and pushes the cask; `brew install --cask
   giraphant/tap/marple` installs both the app and `marple-cli`.

## Risks / open items

- **MLX under hardened runtime** — primary risk (component 3). May need
  entitlement tuning; gated by the behavioral success criterion.
- **Bundle-less SPM nuances** — marple is a bundle-less SPM executable; resource
  lookups (metallib) already handled by `build-app.sh`. Signing must not break
  the colocated `mlx.metallib` lookup. Verify post-sign launch.
- **DMG size** — embedding models are pulled at runtime (HuggingFace), not
  bundled, so the DMG stays small (app + metallib). Confirm no model blobs leak
  into the bundle.
