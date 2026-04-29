# Tree-sitter Parity Current-State Audit - 2026-04-29

Source documents:

- `docs/audits/gap-report-260428.md`
- `docs/audits/gap-report-260428-status.md`
- `docs/plans/audit-findings-plan-2026-04-28.md`
- `compat_targets/shortlist_report.json`
- `compat_targets/parser_boundary_probe.json`
- `compat_targets/deferred_real_grammar_classification.json`

## Result

The 2026-04-28 gap report is no longer an active implementation queue. Its
high-priority concrete findings have either been closed or superseded by later
work, and the compatibility report now records no active audit gaps from that
cycle.

The remaining useful work is therefore not to continue that old audit item by
item. The next parity push should measure and reduce current gaps against a
single large real grammar.

## Old Finding Classification

Closed:

- `add_primary_state_id_list`: serialization emits `primary_state_ids` and the
  generated C language object wires `ts_primary_state_ids`.
- Emitted parser error-cost pruning: generated parser versions carry weighted
  `error_cost`, and pruning uses it before dynamic precedence.
- Per-target build config: compatibility targets can load
  `build_config.json`, including Haskell closure-pressure settings.
- Runtime recovery strategies 2 and 3: focused behavioral coverage exists for
  skip-and-relex and extended error span accounting.
- `MAX_VERSION_COUNT_OVERFLOW`: version pruning has overflow-gated behavior.
- Incremental reuse guards: lookahead, changed, fragile, error, and nested
  unsafe subtree guards are covered.
- Expected-conflict equivalence: positive and negative multi-conflict fixtures
  compare against upstream behavior.
- Generic runtime proof configuration: promoted runtime-link scanner targets
  dispatch through `runtime_proof_config.json`.
- Complex scanner promotion for this audit cycle: JavaScript, Python,
  TypeScript, and Rust scanner targets have focused accepted and invalid proof
  paths.

Superseded:

- Hardcoded Haskell closure-pressure experiments are superseded by target
  config and are no longer the promoted path.
- Language-specific scanner dispatch is superseded by proof-id dispatch for the
  promoted scanner targets. Scanner ABI adapters still exist where the fixture
  needs target-specific C scanner integration.
- The old `prepare_only` wording for JavaScript, Python, TypeScript, and Rust
  is superseded by current shortlist evidence: parser-only JSON targets now
  reach bounded parser-C emission and compile-smoke, while scanner-specific
  runtime proof targets remain separate.

Measurement-gated:

- DAG-level stack replacement should wait for a concrete version-explosion
  sample or runtime divergence.
- Further SymbolSet or key compression should wait for fresh profile evidence
  showing allocation churn in a promoted target.
- Emitted C shape tuning should wait until compile time is again a current
  blocker.

Still active from the old audit:

- None. New work should be tracked as fresh parity gaps below.

## Current Active Gaps

1. Parser-table parity for a large real grammar is not yet explained by direct
   current comparison artifacts. The next work needs a bounded local/upstream
   comparison for one primary grammar, including enough keys to say whether any
   mismatch is in preparation, closure, conflict resolution, minimization,
   serialization, lexing, or generated C emission.
2. External scanner runtime proof coverage is focused and sample-sized. It now
   proves important accepted and invalid scanner surfaces, but it does not yet
   prove broader multi-token behavior for a primary grammar.
3. Generated runtime semantics remain proven through temporary result APIs and
   focused proof parsers. Full upstream tree/recovery shape parity is not yet a
   project claim.
4. Curated corpus compatibility evidence is missing for a large real grammar.
   The project has bounded target checks, but not a small checked-in corpus
   runner that compares selected real samples.
5. Performance budgets exist implicitly through bounded commands and current
   reports. The next promoted large-grammar work should record explicit per
   target wall-clock and memory budgets before moving into routine test paths.

## Primary Grammar

Use JavaScript as the first primary real grammar for this parity plan.

Reasons:

- It has both parser-only and external-scanner targets in the current
  compatibility shortlist.
- The current scanner proof config already covers several accepted and invalid
  scanner paths, so parser-table and scanner-runtime work can use the same
  grammar family.
- It is smaller than TypeScript and likely easier to debug before applying the
  same algorithmic fixes to the TypeScript family.

Fallback:

- Use Rust only if JavaScript comparison output is too broad to isolate a first
  parser-table fix. Rust has strong scanner samples and a smaller scanner
  promotion surface.

## Phase 2 Starting Point

The first implementation batch after this audit should run:

```
zig build run-compare-upstream -Dupstream-compare-grammar=compat_targets/tree_sitter_javascript/grammar.json -Dupstream-compare-output=.zig-cache/upstream-compare-javascript -Dtree-sitter-dir=../tree-sitter
```

Then inspect `.zig-cache/upstream-compare-javascript/local-upstream-summary.json`
and update the plan with the first concrete parser-table parity gap.

## Verification

The current compatibility report was rechecked with:

```
zig build test-compat-full --summary all -Dtest-filter='renderRunReportAlloc matches the checked-in shortlist report artifact'
```

The check passed and did not require a checked-in report refresh.
