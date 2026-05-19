# Manual verification — Reader deep search rollout

## Automated stack verification

`reader-core/tests/integration_hybrid.rs::fixture_vault_round_trip`
(opt-in via `--ignored`) was run on 2026-05-19 and passed in 86.10 s. This
exercises the full production stack end-to-end:

- `init_sqlite_vec()` registers the auto-extension
- `build_sqlite_index` populates `entries` + `entry_vectors_staging`,
  embeds the 2 fixture markdown files with BGE-M3, swaps into
  `entry_vectors`
- `ModelHandle` lazy-loads BGE-M3 on first hybrid call
- `search_entries(mode=Lex)` against `cyborg manifesto` returns the
  English `sample-en.md` only (no shared tokens with the Chinese doc)
- `search_entries(mode=Hybrid)` against the same query also returns the
  Chinese `sample-zh.md` (赛博格宣言), confirming cross-language vec
  recall and RRF fusion

This is the strongest evidence we have until a full-vault rebuild
completes. Failure modes to watch for in the full vault (covered by
spec error handling but not exercised by 2 docs):

- adaptive over-fetch when `type=` filter narrows aggressively
- model state machine under concurrent first-callers
- cosine 0.45 floor suppressing irrelevant typo recall

## Pending: full-vault verification

`npm run build:index` against the real 13825-entry vault is a one-shot
~80 min job (CPU; Metal ~20 min). It is not run by the automated test
suite — the user triggers it manually after merging. Verdict template:

```
Date:
Verdicts:
  - biopower → 生命权力 cross-lang:  PASS / FAIL
  - 生命权力 → English biopower:     PASS / FAIL
  - cyborg mixed CN/EN:              PASS / FAIL
  - NL question recall:              PASS / FAIL
  - technology of the self:          PASS / FAIL
  - AI no high-freq collapse:        PASS / FAIL
  - fucault typo suppression:        PASS / FAIL
```

If any line FAILs, do not delete `reader/rust/reader-spike/` and open
a follow-up before iterating.
