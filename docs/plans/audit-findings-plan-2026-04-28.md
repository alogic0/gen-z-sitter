# Audit Findings Plan — 2026-04-28

Source audit: `docs/audits/gap-report-260428.md`.

This plan starts after `tree-sitter-gap-reduction-2026-04-28.md` was closed.
Some audit findings were already fixed by later batches, so this file records
the current status before defining the next implementation order.

## Current Audit Status

Closed since the audit:

- `add_primary_state_id_list`: `src/parse_table/serialize.zig` computes
  `SerializedTable.primary_state_ids`, `src/parser_emit/parser_c.zig` emits
  `ts_primary_state_ids`, and `TSLanguage.primary_state_ids` is wired.
- Emitted parser error-cost surface: generated parse versions and
  `TSGeneratedParseResult` now carry `error_cost`, and version pruning uses
  weighted cost.
- Per-target build config: `src/compat/harness.zig` loads
  `compat_targets/<target>/build_config.json` and applies
  `closure_pressure_mode = thresholded_lr0` for Haskell.
- Hardcoded Haskell closure-pressure state/symbol experiments: removed from the
  promoted path and replaced by target config.
- Scanner-state GLR condensation: emitted generated parsers avoid merging
  versions with different serialized external scanner payloads.
- Scanner-aware local incremental sample: a sampled Haskell-layout fixture now
  blocks unsafe scanner-state reuse.

Still active from the audit:

- Behavioral harness uses error-count and simple cost approximations in places
  where upstream relies on subtree error cost.
- Behavioral harness does not model `MAX_VERSION_COUNT_OVERFLOW`.
- Behavioral and emitted GLR stacks still use array-based version storage
  instead of upstream DAG-level `ts_stack_merge` semantics.
- Recovery strategies 2 and 3 remain incomplete: skip-and-relex and
  extend-error-span behavior need focused parity work.
- Incremental reuse guards are incomplete: first-leaf lookahead, changed,
  fragile, and error subtree guards are missing.
- Expected-conflict equivalence is covered by local summaries but not by a
  direct multi-conflict upstream comparison proof.
- Complex scanner grammars remain intentionally gated until the GLR/runtime
  evidence is stronger.
- Runtime-link dispatch still uses target-name branches; the next cleanup is a
  generic per-target runtime proof config.

Deferred unless measurements demand them:

- Full DAG stack replacement for performance-only reasons.
- Further SymbolSet/key compression.
- Emitted C shape tuning.

## Phase 1 — Correct the Audit Baseline

Goal: keep future work pointed at live gaps only.

- [x] Add a small status addendum for `gap-report-260428.md` that records which
  audit items are now closed or superseded.
- [x] Add tests or artifact checks that prove `primary_state_ids` and emitted
  `error_cost` stay wired, because those were high-priority audit findings.
- [x] Make compatibility reports include a compact "audit gap status" section
  for the still-open runtime and incremental gaps.

Batch 1 note: `docs/audits/gap-report-260428-status.md` now corrects stale
audit findings. `shortlist_report.json` includes an `audit_gap_status` block
with closed, active, and measurement-gated findings. The report renderer test
asserts that the closed `primary_state_ids` and emitted `error_cost` findings,
plus the active incremental guard gap, remain visible in the generated report.

Gate:

- A maintainer can read one current file and see which audit findings still
  require implementation.

## Phase 2 — Runtime Recovery Parity

Goal: make invalid-input behavior closer to upstream before promoting more
complex scanner grammars.

- [ ] Audit upstream recovery strategies 2 and 3 against current emitted parser
  and behavioral harness code.
- [ ] Add focused behavioral fixtures where upstream skip-and-relex succeeds
  but current local parsing rejects or produces a weaker error tree.
- [ ] Implement skip-and-relex recovery in the behavioral harness.
- [ ] Implement skip-and-relex recovery in emitted generated parsers.
- [ ] Add focused behavioral fixtures for extend-error-span recovery.
- [ ] Implement extend-error-span accounting in behavioral and emitted parser
  paths.
- [ ] Compare JSON/Ziggy invalid tree strings after each recovery change.

Gate:

- Existing invalid runtime-link samples remain green, and at least one focused
  strategy-2 or strategy-3 fixture proves the new path.

## Phase 3 — Error Cost and Version Pruning Parity

Goal: avoid keeping a different parse version than upstream on invalid or
ambiguous input.

- [x] Add `MAX_VERSION_COUNT_OVERFLOW` to the behavioral harness and emitted
  generated parser constants.
- [x] Replace remaining count-only behavioral pruning decisions with error-cost
  decisions.
- [x] Add fixtures with equal error counts but different skipped-byte costs.
- [x] Add fixtures where dynamic precedence only wins after equal error cost.
- [x] Record `error_cost`, `error_count`, and dynamic precedence in runtime-link
  proof output where useful.

Batch 2 note: behavioral parse versions now carry `error_cost` alongside
`error_count`. Missing-action recovery charges stack recovery and byte skips as
1, and skipped known tokens by byte length. Condensation prunes high-cost
versions only after the overflow threshold, merges duplicate positions by lower
error cost first, and uses dynamic precedence only as the equal-cost
tie-breaker. Generated parser C now emits `GEN_Z_SITTER_MAX_PARSE_VERSION_OVERFLOW`
and applies the same overflow-gated cost threshold.

Batch 3 note: direct generated-result runtime-link proofs can now assert
`error_count`, `error_cost`, and `dynamic_precedence` from
`TSGeneratedParseResult`. The no-external GLR result proof locks the valid
zero-error path to all three values.

Gate:

- Behavioral and emitted parser tests show cost-based pruning beats count-only
  pruning in a focused fixture.

## Phase 4 — Incremental Reuse Guards

Goal: match upstream subtree reuse rejection before expanding scanner-aware
incremental coverage.

- [x] Extend the local parse-node model with enough metadata to represent
  changed, fragile, and error subtrees.
- [x] Add `first_leaf_symbol` tracking or a conservative equivalent in reusable
  nodes.
- [x] Reject reuse when the first leaf does not match the current lookahead.
- [x] Reject reuse for changed, fragile, and error subtrees.
- [x] Add scanner-free tests for each guard.
- [x] Add a scanner-aware Bash or Haskell sample after the guard logic is
  stable.

Batch 4 note: `ParseNode` now carries first-leaf, changed, fragile, and error
metadata for incremental reuse decisions. Reuse is rejected when the current
lookahead does not match the old subtree's first leaf or when any reused
subtree is changed, fragile, or an error subtree. Scanner-free guard tests cover
each rejection reason, and the existing sampled Haskell-layout incremental
fixture keeps the scanner-aware reuse boundary covered after the guard change.

Gate:

- Incremental tests cover accepted reuse and every explicit upstream-style
  rejection reason.

## Phase 5 — Expected Conflict Equivalence

Goal: move from local conflict summaries to direct multi-conflict parity
evidence.

- [ ] Add or identify a grammar with multiple expected conflicts that upstream
  accepts.
- [ ] Emit local conflict-summary keys for expected-conflict set identity, not
  only counts.
- [ ] Compare unused expected-conflict indexes against upstream behavior.
- [ ] Add a negative fixture where one expected conflict is missing and both
  generators reject with the same useful parent-rule surface.

Gate:

- A multi-conflict fixture proves local expected-conflict matching does not
  accept a grammar upstream rejects.

## Phase 6 — Generic Runtime Proof Configuration

Goal: remove target-name dispatch from the compatibility harness before adding
more real grammars.

- [ ] Design a JSON runtime-proof config that can name sample files, expected
  proof level, external scanner source, compile/link requirements, and known
  blocked surfaces.
- [ ] Move Bash, Haskell, JavaScript, TypeScript, Python, and Rust scanner proof
  metadata into per-target config files.
- [ ] Replace `runScannerRuntimeLinkProof` target-name branching with a generic
  config-driven dispatcher where possible.
- [ ] Keep custom Zig functions only for fixtures whose scanner ABI needs a
  real adapter, and identify those explicitly in config.
- [ ] Update compatibility reports to show which proof config drove each
  target.

Gate:

- Adding a new simple scanner target should require a config file and fixture
  files, not a new target-name branch in Zig.

## Phase 7 — Complex Scanner Promotion

Goal: increase real grammar reach after recovery, pruning, incremental guards,
and proof config are stronger.

- [ ] Re-run bounded boundary probes for JavaScript, Python, TypeScript, and
  Rust after Phases 2-6.
- [ ] Promote one target at a time from prepare-only to parser.c emission.
- [ ] Promote compile-smoke targets to accepted runtime-link samples only after
  a focused scanner proof exists.
- [ ] Add invalid runtime-link samples only after recovery parity is stable for
  that target family.
- [ ] Keep thresholded/coarse modes diagnostic unless a target config documents
  why they are part of the promoted proof.

Gate:

- At least one currently prepare-only complex scanner grammar advances one
  compatibility boundary without raising bounded-suite cost beyond the accepted
  limit.

## Implementation Order

1. Phase 1: correct the audit baseline and keep the current status visible.
2. Phase 3: finish low-risk error-cost/version-pruning parity constants and
   focused fixtures.
3. Phase 4: add incremental reuse guards while the local harness is still easy
   to reason about.
4. Phase 2: implement recovery strategies 2 and 3 with focused invalid-input
   fixtures.
5. Phase 5: strengthen expected-conflict equivalence once runtime behavior is
   stable again.
6. Phase 6: make runtime proof configuration generic.
7. Phase 7: promote the next complex scanner grammar one boundary at a time.

Do not start Phase 7 until the earlier phases give enough runtime evidence to
debug real grammar failures without guessing.
