# Next Steps — 2026-04-26

State after M43 (lexer parity), M44 (lexer-state milestone), and M45 Phases 1–4
(parse-table algorithm convergence).

---

## What Is Done

- **M45 Phase 1** — Precomputed closure additions; `ClosureResultCache` removed.
- **M45 Phase 2** — Multi-action table built during state construction;
  unresolved multi-action entries serialized; `TSUnresolved` side tables and
  lookup helpers emitted in generated C.
- **M45 Phase 3 infrastructure** — `expected_conflicts` loaded from grammar JSON;
  `ExpectedConflictPolicy` helper; reduce/reduce expected-conflict routing;
  `unusedExpectedConflictIndexesAlloc` hook; `expectedConflictReportFromPreparedAlloc`
  in pipeline; tested in isolation.
- **M45 Phase 4 bounded minimization** — optional `--minimize` path, core-gated
  state minimization, behavioral equivalence coverage, bounded compat
  minimization probes, and `zig build run-minimize-report`.
- **Compat coverage** — C JSON, Haskell, Bash at `full_runtime_link`; Zig grammar
  target added; `TSCharacterRange` large-charset indexing done.
- **Performance** — SymbolSet bitset (7.5× bool_alloc_mb reduction); lexer
  minimization signature filter; parse-action hash index; closure-expansion cache.

---

## Priority 1 — M45 Phase 3 Completion: Wire Conflict Reporting into CLI

**What is missing.**

`expectedConflictReportFromPreparedAlloc` exists in `src/parse_table/pipeline.zig`
and is exercised in tests, but nothing in the CLI or harness calls it on a real
grammar run. Concretely:

- Unused `expected_conflicts` declarations produce no user-visible warning.
- The `hasUnusedExpectedConflicts()` flag is never checked outside tests.
- Shift/reduce conflicts are not yet routed through `ExpectedConflictPolicy`
  (only reduce/reduce is).

**Work.**

1. Call `expectedConflictReportFromPreparedAlloc` in the CLI generate path
   (`src/cli/command_generate.zig` or `src/compat/harness.zig`) after build.
2. If `report.hasUnusedExpectedConflicts()`, emit a structured warning:
   ```
   warning: expected_conflicts[N] declared but no conflict found: ["rule_a", "rule_b"]
   ```
3. Route shift/reduce conflict candidates through the same `ExpectedConflictPolicy`
   matching already used for reduce/reduce.
4. Add a compat fixture that declares `expected_conflicts`, verifies no error, and
   verifies the unused-warning fires when the conflict disappears.

**Gate.** All existing compat targets pass unchanged. Unused-conflict warning fires
correctly on the new fixture.

---

## Priority 2 — M45 Phase 4: State Minimization

**Current state.**

The bounded/local Phase 4 path is implemented. `--minimize` is wired into JSON
summary generation, the minimizer is gated by item-set cores, the behavioral
harness compares minimized and unminimized outcomes, and
`zig build run-minimize-report` reports bounded staged-target state counts plus
explicit skips for heavy real-grammar or JS-loader targets.

**Remaining manual gate.**

Do not fold heavy real-grammar minimization checks into fast unit tests. If a
future change claims broad minimization coverage, run selected large
compatibility targets manually and compare default/minimized state counts.

**Local gate.** Use `zig build run-minimize-report` plus the bounded local test
set documented in `MILESTONES_45.md`.

---

## Priority 3 — Pipeline Goldens Refresh

The `zig build test-pipeline` suite still uses pre-EOF-era string snapshots.
All test-pipeline targets are isolated from `test-compat-heavy` and `test` so
this does not affect CI, but the suite stays red.

**Work.** Regenerate the goldens with a single command (whatever `--update` or
`--bless` flag the pipeline suite accepts) and commit the refreshed snapshots.

---

## Priority 4 — M47 Tree Builder (Prerequisite for Incremental Parsing)

`docs/incremental-parsing-plan.md` documents the full M47 plan. The blocking
prerequisite is a `ParseNode` type and a value stack in the behavioral harness.
Without a concrete syntax tree there is nothing to reuse incrementally.

**Minimum work to unblock M47.**

Per the plan (`src/behavioral/`):

1. Add `ParseNode` to `src/behavioral/`:
   ```zig
   pub const ParseNode = struct {
       production_id: u32,
       start_byte: u32,
       end_byte: u32,
       entry_state: u32,
       children: []ParseNode,
       is_error: bool,
   };
   ```
2. Add a parallel value stack to each `ParseVersion` in `harness.zig`.
3. On shift: push a terminal `ParseNode` with byte range.
4. On reduce: pop N children, produce a parent `ParseNode`.
5. Thread `tree: ParseNode` out of `SimulationResult.accepted`.

**Gate.** Existing behavioral harness tests still pass. A new test parses
`"1+2+3"` and asserts the root node has two `+` children with correct byte ranges.

This does not yet implement incremental reuse — it only builds the tree that
reuse requires. The full incremental proof-of-concept follows in M47 proper.

---

## Deferred / Low Priority

- **Compiler optimization pragmas** (`#pragma GCC optimize ("O0")` for lex tables
  > 300 states) — no correctness impact; affects C compile time for large grammars.
  From `docs/gap-audit-260426.md` Gap 3.
- **GLR runtime walk of TSUnresolved side tables** — the C side table is emitted
  (Phase 2 complete), but the tree-sitter C runtime does not yet walk it. This
  lives in the runtime, not the generator.

---

## Execution Order

```
Phase 3 reporting polish  →  Pipeline goldens  →  M47 tree builder
```

Phase 4's bounded/local path is complete. Pipeline goldens is always independent.
M47 tree builder is the highest-effort item and should follow after M45 is fully
closed.
