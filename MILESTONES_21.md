# MILESTONES 21 (Optimization Later)

This milestone covers the longer-tail generator work that remains after the currently active milestone sequence.

Use this file for follow-on implementation once the active milestone work in [MASTER_PLAN.md](./MASTER_PLAN.md) and [MASTER_PLAN_2.md](./MASTER_PLAN_2.md) has moved far enough that broader generator parity and optimization become the immediate priority.

## Fuller Generator Parity

- [x] fuller parser output closer to upstream `parser.c`
- [x] lexer/scanner emission
- [x] external scanner integration
- [ ] parse-table compression/minimization
- [ ] broader real-grammar/repo compatibility coverage
- [ ] compatibility polish and ergonomics after correctness is credible

Current first optimization slice:

- emitted `parser.c` now shares canonical empty action and goto arrays instead of re-emitting identical empty arrays for every empty state
- emitted `parser.c` now also reuses the first canonical non-empty action/goto/unresolved arrays when later states serialize the exact same row contents
- `generate --json-summary` now reports parser-table and parser.c row-sharing stats so compression wins stay measurable before deeper minimization work
- emitted `parser.c` now compacts exact duplicate serialized states and remaps in-table shift/goto targets to the canonical surviving state before row sharing runs
- the same exact-duplicate serialized-state compaction now also applies to the parser-table and C-table emitter surfaces, not just `parser.c`
- the existing `--no-optimize-merge-states` flag now disables that emitted-surface duplicate-state compaction path in the JSON summary/emitter option flow
- `generate --json-summary` now reports both serialized-state counts and emitted-state counts, plus the active compaction toggle, so optimization wins are explicit in one summary
- `generate --json-summary` now also reports baseline-vs-emitted row-sharing stats, so row-level savings are visible without manually toggling options and diffing results
- `generate --json-summary` now also reports explicit savings deltas, including emitted-state reduction and emitted array-definition savings, so the optimization impact is directly quantified
- `generate --json-summary` now also reports baseline-vs-emitted byte sizes for `parser_tables`, `c_tables`, and `parser.c`, so output-size savings are measurable across every emitted surface
- this is intentionally a low-risk compression step:
  - it reduces repeated emitted boilerplate
  - it only shares rows when the serialized action/value/target contents are exactly equal
  - it now also removes exact duplicate serialized states from the emitted table/debug surfaces when their full action/goto/unresolved rows match
  - it makes the current sharing wins visible and reports how many emitted parser.c states were collapsed
  - it renumbers only the emitted surface state ids after compaction and remaps in-table targets accordingly
  - it is now explicitly switchable for comparison/debugging through the existing optimization toggle path
  - it now exposes both the pre-optimization and post-optimization emitted state counts in the summary path
  - it now exposes both the baseline and post-optimization row-sharing stats in the summary path as well
  - it now quantifies the emitted savings directly in the summary path instead of leaving them implicit in before/after numbers
  - it now quantifies emitted byte-size savings across all current emitter surfaces in the summary path as well
  - it does not change the staged compatibility contract
  - it preserves existing parser behavior and test coverage

Immediate promotion candidates after the first behavioral-equivalence stage:
- [x] turn `lexer/scanner emission` into a dedicated execution checklist
- [x] decide whether `external scanner integration` stays coupled to that same checklist or becomes a separate follow-on checklist
- [x] make `external scanner integration` a separate follow-on checklist
- [x] complete the first external-scanner follow-on checklist
- [x] decide whether `broader real-grammar/repo compatibility coverage` waits on lexer/scanner support or starts with parser-only repo cases first

Decision:
- start with parser-only repo cases first
- do not wait on broader lexer/scanner support before beginning that coverage expansion

Why this is the current order:
- the current compatibility boundary is explicitly scanner-free, so parser-only repo cases extend the proven surface without changing the contract being tested
- this keeps Milestones 21 focused on measurable parser-generator progress instead of mixing parser coverage growth with scanner/runtime unknowns
- lexer/scanner-heavy repos can still follow later as a second wave once the parser-only compatibility harness is broader and cheaper to iterate on

Initial parser-only repo coverage target shape:
- repos/grammars that can run against the current parser-only emitted boundary without requiring external scanners
- emphasis on fixture-driven compile, emit, and structural comparisons before deeper behavioral claims
- promote this into its own milestone file once a concrete repo shortlist and harness boundary are written down

Promoted milestones:
- [x] [MILESTONES_18.md](./MILESTONES_18.md)
- [x] [MILESTONES_19.md](./MILESTONES_19.md)

## Notes

- These items are intentionally separated from the active milestone sequence.
- They are still real project work, but they should not dilute the milestone-by-milestone closeout process in `MASTER_PLAN.md`.
- When one of these becomes the next concrete implementation target, it should usually be promoted into its own milestone file first.
- The completed behavioral-equivalence stage establishes only the first scanner-free parser-walk boundary; broader real-grammar/repo coverage remains active later work here.
