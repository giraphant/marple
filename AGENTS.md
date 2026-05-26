# CLAUDE.md

## 0. Learn From Others

When you want to create or modify something, double-check if there is established open-source app (e.g. fsnotes, NetNewsWire, CotEditor)we can use as an example (https://github.com/serhii-londar/open-source-mac-os-apps#editors) and how they achieve specific functions: animations, layouts etc.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

## 5. Linear (Issue Tracking)

The `linear` CLI is the source of truth for tasks. Team key: **QUA** (Quasi Fish). Recent commits already reference issue IDs (e.g. QUA-89, QUA-78).

**Start of session** — if the task references an existing issue, pull its context first:
- `linear i get QUA-89` — full issue + description
- `linear i comments QUA-89` — discussion thread
- `linear i list` — your assigned issues
- `linear search "<keyword>"` — find related issues

**Before opening a PR or merging** — if any TODOs remain unfinished (deferred work, known limitations, follow-ups surfaced during the change), file them in Linear so they aren't lost in code comments or chat:
- `linear i create "Short title" -t QUA -d "Why deferred + link to PR/commit" -p 3`
- Reference the new issue ID in the PR body.

Run `linear --help` for the full command reference. Don't create issues for trivial in-session steps — only for work that survives the PR.