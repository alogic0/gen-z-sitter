# Tree-sitter Parity Plan — 2026-04-29

Goal: move from closing known audit findings to reducing the remaining
implementation gap with upstream Tree-sitter on real grammars, generated C
runtime behavior, external scanners, and bounded corpus evidence.

This plan starts after `docs/plans/audit-findings-plan-2026-04-28.md` was
closed. That plan moved the known 2026-04-28 audit findings into either closed
or measurement-gated status. The next work should therefore begin with a fresh
current-state audit instead of continuing to implement stale items.

## Ground Rules

- Keep generated upstream artifacts out of source control.
- Do not vendor Tree-sitter source files into this project.
- Implement algorithms in Zig and keep the generator self-contained.
- Treat `../tree-sitter` as the algorithm reference checkout.
- Prefer one primary real grammar at a time when debugging algorithm gaps.
- Keep normal test commands bounded; promote a target only when it has stable
  time and memory behavior.
- Record every promoted boundary in checked-in compatibility artifacts.
- Do not convert diagnostic coarse/thresholded modes into correctness claims
  unless the target config explicitly documents why that is acceptable.

## Phase 1 — Fresh Current-State Audit

Goal: replace the now-closed audit plan with a current, accurate implementation
map.

- [x] Re-run the current compatibility report and preserve the refreshed
  checked-in summary only if it changes for a meaningful reason.
- [x] Re-read `docs/audits/gap-report-260428.md` against current code.
- [x] Classify each old finding as closed, superseded, measurement-gated, or
  still active.
- [x] Add a new audit status document under `docs/audits`.
- [x] Update this plan with concrete active gaps discovered by the audit.
- [x] Pick the primary real grammar for the next parity push.

Batch 1 note: `docs/audits/tree-sitter-parity-current-state-2026-04-29.md`
classifies the old 2026-04-28 findings as closed, superseded, or
measurement-gated. No active old-audit findings remain. The current active gaps
are direct parser-table parity for one large real grammar, broader multi-token
scanner proof coverage, generated runtime semantics, curated corpus evidence,
and explicit large-target performance budgets. JavaScript is the primary grammar
for this plan, with Rust as the fallback if JavaScript comparison output is too
broad for the first parser-table fix.

Recommended first primary grammar:

- JavaScript, because it has both parser-only and external-scanner targets in
  the current shortlist, plus multiple accepted and invalid scanner proof
  samples.

Fallback primary grammar:

- Rust, if JavaScript parser-table differences are too broad for the first
  batch. Rust has a smaller scanner promotion surface and a focused raw-string
  invalid proof.

Gate:

- One current audit document names the live gaps, and this plan is updated to
  implement them in order.

## Phase 2 — Parser Table Parity For One Large Grammar

Goal: make the primary real grammar explainable at the parser-table level
before adding broader runtime claims.

Primary grammar: JavaScript

Starting command:

```
zig build run-compare-upstream -Dupstream-compare-grammar=compat_targets/tree_sitter_javascript/grammar.json -Dupstream-compare-output=.zig-cache/upstream-compare-javascript -Dtree-sitter-dir=../tree-sitter
```

Batch order:

- [x] Run the JavaScript local/upstream comparison command and inspect
  `.zig-cache/upstream-compare-javascript/local-upstream-summary.json`.
- [x] Record the first concrete JavaScript parser-table parity gap in this
  plan.
- [x] Add or refine comparison artifacts only if the current summary is too
  coarse to classify the gap.
- [ ] Add the smallest focused fixture that reproduces the discovered gap.
- [ ] Implement the smallest upstream-aligned fix.
- [ ] Re-run the JavaScript comparison and refresh only affected checked-in
  artifacts.

- [x] Run local parser-state, item-set, conflict, minimization, lex-table, and
  parser-C summaries for the primary grammar.
- [x] Run bounded upstream comparison for the same grammar using `../tree-sitter`.
- [x] Identify whether the blocker is grammar preparation, item-set closure,
  conflict resolution, minimization, serialization, lexing, or C emission.
- [x] Add or refine comparison keys where the current artifacts are too coarse.
- [ ] Add a focused regression fixture for the smallest discovered algorithm
  difference.
- [x] Implement the first focused upstream-aligned parser-table fixes.
- [ ] Replace the partial inline expansion with upstream-style extracted-symbol
  replacement/removal so inlined/tokenized syntax variables do not remain as
  parser variables.
- [ ] Refresh only the affected golden/report artifacts.

Batch 2 note: JavaScript comparison now writes
`.zig-cache/upstream-compare-javascript/local-upstream-summary.json`. Two
comparison infrastructure gaps were fixed first: runtime-only parse-action lists
can now omit unresolved diagnostic candidate rows for bounded comparison and
state compaction, and corpus runner compile failure is recorded in the corpus
section instead of aborting parser-table comparison. The first concrete
JavaScript parser-table gap is conflict/parse-table construction: local
JavaScript is still `blocked=true`, has 11,157 serialized states, and reports
24,976 unresolved decisions; upstream emits an unblocked parser with 1,870
states. The smallest visible surface to reduce next is expected-conflict and
reserved-identifier conflict handling, starting from the unresolved samples in
the generated `local/conflict-summary.json`.

Batch 3 note: two focused parser-table fixes landed locally and pass the fast
unit suite: reserved-word FIRST propagation through nested symbols, and
expected-conflict candidate expansion through auxiliary parent symbols. The
JavaScript comparison showed that these are correct local pieces but not enough
to unblock JavaScript. A bounded token-like inline expansion then moved the
first visible conflict sample from `_reserved_identifier` to `primary_expression`,
which confirms that inline declarations are part of the active gap, but the
partial implementation is not a valid promotion boundary: JavaScript grew from
11,157 to 12,618 states and from 24,976 to 31,339 unresolved decisions. The next
required parser-table step is not broader conflict resolution; it is
upstream-style symbol replacement/removal during token extraction/inlining, so
extracted inline variables like `_reserved_identifier`, `_identifier`, and
`_semicolon` do not remain as independent parser variables.

Gate:

- The primary grammar has either advanced one parser-table boundary or has a
  precise checked-in explanation of the next unresolved algorithm gap.

## Phase 3 — External Scanner Runtime Expansion

Goal: move from single-token scanner proofs toward realistic multi-token
scanner behavior without making routine tests heavy.

- [ ] For the primary grammar, add one multi-token accepted scanner sample.
- [ ] Add runtime proof config metadata for the sample file and proof id.
- [ ] Assert generated parser metrics where stable: consumed bytes, error
  count, error cost, and dynamic precedence.
- [ ] Add scanner serialize/deserialize checks if the scanner state changes
  across the sample.
- [ ] Add one invalid scanner sample only after the accepted path is stable.
- [ ] Keep target runtime under the accepted bounded-suite cost.

Gate:

- One real scanner target proves more than an isolated external token and still
  passes through the generic runtime proof config path.

## Phase 4 — Generated Runtime Semantics

Goal: reduce behavioral differences between the generated parser runtime and
upstream parser behavior.

- [ ] Audit generated GLR version merge behavior against upstream stack
  semantics for the primary grammar sample.
- [ ] Add focused runtime-link tests for scanner-state preservation across
  multiple parse versions.
- [ ] Add focused invalid-input tests for recovery tree shape where the current
  temporary API exposes enough information.
- [ ] Add incremental parsing samples for the primary grammar when scanner
  state is involved.
- [ ] Record remaining temporary API limits explicitly instead of hiding them
  in test names.

Gate:

- Runtime-link tests cover at least one accepted, one invalid, and one
  scanner-state-sensitive path for the primary grammar or a reduced fixture
  derived from it.

## Phase 5 — Bounded Corpus Compatibility

Goal: start proving real grammar behavior on curated corpus samples without
running the full upstream corpus.

- [ ] Add a bounded corpus runner for one grammar.
- [ ] Start with three curated samples: smallest accepted, scanner accepted,
  and invalid/recovery.
- [ ] Compare accepted/error status and root tree string where stable.
- [ ] Record divergences as structured artifacts with sample labels and
  mismatch categories.
- [ ] Keep corpus execution out of fast unit tests unless the samples are very
  small.

Gate:

- One real grammar has checked-in curated corpus evidence that can be rerun
  without hanging or exhausting memory.

## Phase 6 — Performance And Bounds

Goal: keep larger grammar work usable on a development machine.

- [ ] Add or confirm per-target wall-clock and memory budgets for promoted
  compatibility steps.
- [ ] Add stage-level timing where a promoted target approaches its budget.
- [ ] Profile only the slowest current stage for a target.
- [ ] Avoid structural performance rewrites until measurements identify the
  dominant cost.
- [ ] Document intentionally heavy tests and keep them outside routine test
  commands.

Gate:

- Promoted compatibility work remains bounded, and any expensive target has a
  clear diagnostic command rather than being part of normal unit tests.

## Phase 7 — Release Boundary Update

Goal: align documentation with the implementation evidence after the parity
work advances.

- [ ] Update the release boundary inventory after the primary grammar moves.
- [ ] Update README and HOWTO wording for supported grammar classes.
- [ ] Document which generated parser surfaces are stable and which remain
  temporary.
- [ ] Document what users can rely on for parser-only grammars, external
  scanner grammars, generated C output, and highlighter use cases.
- [ ] Add a short "known limits" section pointing to current audit/status docs.

Gate:

- User-facing docs match the compatibility evidence rather than the intended
  future state.

## Implementation Order

1. Phase 1: create the fresh audit and choose the primary grammar.
2. Phase 2: reduce or precisely classify the primary parser-table gap.
3. Phase 3: expand scanner runtime proof coverage for the same grammar.
4. Phase 4: tighten generated runtime semantics around the discovered samples.
5. Phase 5: add bounded curated corpus evidence.
6. Phase 6: enforce performance bounds as soon as a promoted target becomes
   expensive.
7. Phase 7: update user-facing release and usage documentation after evidence
   changes.

Do not start broad corpus work until the primary grammar's parser-table and
scanner-runtime boundaries are clear enough to debug failures without guessing.
