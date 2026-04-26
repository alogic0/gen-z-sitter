# ReWrite-4.1: Same-Auxiliary Repeat Conflict Resolution

**Goal**: implement the upstream Tree-sitter repeat-conflict shortcut that handles a
shift/reduce conflict when all conflicting items belong to the same auxiliary parent
symbol. This does not unblock `repeat_choice_seq_js`: that staged grammar is rejected
by upstream Tree-sitter because its remaining conflict reduces `_entry` while shifting
into an internal repeat, so it must stay an explicit blocked compatibility fixture.

**Scope rule**: keep the project self-contained Zig. Do not copy tree-sitter source
files into this project. Use `../tree-sitter` only as a reference.

**Verification rule**: do not run `zig build test-compat-heavy` during this
implementation pass unless explicitly requested. Add focused unit tests and run fast
local/runtime checks first.

---

## Upstream Behavior to Reproduce

Reference: `../tree-sitter/crates/generate/src/build_tables/build_parse_table.rs`,
`handle_conflict` around the repeat-conflict pre-check.

The upstream algorithm does this before normal precedence/associativity resolution:

1. Build `conflicting_items` from the parse state for the conflicting lookahead:
   - unfinished items whose next symbol can begin with the lookahead contribute to the
     shift side;
   - finished items whose lookahead set contains the lookahead contribute to the reduce
     side;
   - start/internal sentinel items are ignored.
2. If the parse-table entry contains a shift action, inspect the parent variable of the
   collected conflicting items.
3. If every conflicting item has the same parent variable and that variable is
   auxiliary, keep the multi-action parse entry and set the shift action's
   `is_repetition` flag. At runtime, reductions are tried before `SHIFT_REPEAT`.
4. Return immediately, before precedence logic.

Important nuance: upstream checks `variable.is_auxiliary()`, not just whether the reduce
production itself is the repeat auxiliary production.

---

## Current Zig Gap

Relevant local code:

- `src/parse_table/resolution.zig::resolveShiftReduce`
- `src/parse_table/resolution.zig::extractShiftResolutionMetadata`
- `src/parse_table/serialize.zig::attachRepetitionShiftMetadataAlloc`
- `src/parse_table/serialize.zig::shiftHasRepeatAuxiliaryConflict`
- `src/parse_table/build.zig::ProductionInfo`

Current Zig behavior already handles two narrower cases:

- prefer shift when the reduce production has `lhs_is_repeat_auxiliary = true`,
- prefer shift when the shift candidate continues a repeat auxiliary production.

It misses the upstream same-parent-auxiliary case in focused valid repeat fixtures.
`repeat_choice_seq_js` is not such a case: upstream rejects it outright with an
unresolved `_entry` shift/reduce conflict and suggests associativity or an explicit
conflict declaration.

Local complication: `actions.ParseAction.shift` does not carry a repetition flag.
Zig chooses the action during resolution, then later attaches `.repetition = true` in
serialization. Therefore the fix has two required parts:

1. Resolution/diagnostics must identify the same-auxiliary conflict class using
   upstream's FIRST-set rule.
2. Serialization must emit a runtime parse-action list that keeps reductions before
   a `.repetition = true` shift for that conflict class.

Implementing only a chosen shift is incomplete because upstream keeps the reduce action
in the runtime action list.

---

## Phase 1 — Model the Upstream Conflict Predicate Locally

- [x] Define a local helper in `resolution.zig` that detects the upstream class for a
  shift/reduce conflict:
  - input: productions, parse state, conflicting lookahead / shift symbol;
  - collect finished reduce-side items whose lookahead contains the symbol;
  - collect unfinished shift-side items whose next step symbol equals the shift symbol
    or whose next step can lead to the shift symbol if the local first-set information is
    already available;
  - ignore invalid production IDs and augmented/start items;
  - require at least one collected item;
  - require every collected item's production LHS to be identical;
  - require that shared LHS has `lhs_kind == .auxiliary`.
- [x] If first-set information is not available in `resolution.zig`, keep the first
  implementation conservative: collect items directly involved in the existing
  shift/reduce group, and add tests proving the target gap shape. Do not add broad
  first-set reconstruction unless needed.
- [x] Prefer checking `lhs_kind == .auxiliary` over name heuristics like `"_repeat"`.
  Keep `lhs_is_repeat_auxiliary` for the existing narrower checks.

---

## Phase 2 — Resolve Same-Auxiliary Shift/Reduce Before Precedence

- [x] In `resolveShiftReduce`, run the same-auxiliary helper before dynamic precedence,
  named precedence, integer precedence, associativity, and the existing repeat-auxiliary
  fallbacks.
- [x] If the helper returns true, keep the table route on the shift action while
  preserving candidate actions for runtime serialization.
- [x] Keep existing precedence behavior unchanged for non-auxiliary conflicts.
- [x] Add a focused `resolution.zig` test for a valid same-auxiliary shape:
  - an auxiliary parent production such as `_entry` with a completed reduce item;
  - a shift item from the same auxiliary parent on the same lookahead;
  - reduce production itself must have `lhs_is_repeat_auxiliary = false`;
  - assert the helper matches upstream's FIRST-set conflict predicate.
- [x] Add a negative test where conflicting items have different LHS values and assert
  the conflict remains unresolved unless another existing rule resolves it.
- [x] Add a negative test where the common LHS is not auxiliary and assert existing
  precedence behavior is unchanged.

---

## Phase 3 — Preserve Runtime Repetition Metadata

- [x] Broaden `serialize.zig::shiftHasRepeatAuxiliaryConflict` to use the same
  same-auxiliary conflict predicate rather than requiring every completed reduce item to
  have `lhs_is_repeat_auxiliary = true`.
- [x] Keep existing support for true repeat-auxiliary productions.
- [x] Ensure `attachRepetitionShiftMetadataAlloc` marks the shifted entry with
  `.repetition = true` for the same conflict shape and that parse-action lists preserve
  reductions before `SHIFT_REPEAT`.
- [x] Add a focused serialization test mirroring the resolution fixture:
  - chosen shift on the conflict symbol;
  - same auxiliary parent;
  - reduce production is not itself repeat auxiliary;
  - assert `serialized.states[*].actions[*].repetition == true`;
  - assert `parse_action_list` also carries `.repetition = true`.
- [x] Add a negative serialization test for non-auxiliary common LHS or mixed LHS.

---

## Phase 4 — Pipeline Fixture Coverage

- [x] Do not use `repeat_choice_seq_js` as promotion evidence; it is an upstream-rejected
  blocked fixture.
- [x] Keep pipeline lex-table tests on an unambiguous grammar so they cannot mask this
  rejected target.
- [x] Assert same-auxiliary repetition behavior in focused resolver/serializer unit
  tests instead of relying on the blocked compatibility fixture.
- [x] If an exact golden exists and would require unrelated EOF/golden churn, prefer a
  focused behavioral/assertion test over refreshing broad string goldens.

---

## Phase 5 — Plan and Gap Documentation

- [x] Update `ReWrite-4_1.md` checkboxes as phases are completed.
- [x] Update target/test notes so `repeat_choice_seq_js` is documented as an
  upstream-rejected control fixture, not a missing same-auxiliary algorithm.
- [x] Do not claim broad compatibility-heavy completion unless the user explicitly asks
  to run that manual gate.

---

## Phase 6 — Verification

Run fast/local verification only:

- [x] `zig fmt --check src`
- [x] `zig build test`
- [x] Focused build steps if they already exist and are lightweight.

Deferred manual gate:

- [x] `zig build test-compat-heavy` — do not run unless explicitly requested.
