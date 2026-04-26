# ReWrite-4.1: Same-Auxiliary Repeat Conflict Resolution

**Goal**: implement the upstream Tree-sitter repeat-conflict shortcut that resolves a
shift/reduce conflict when all conflicting items belong to the same auxiliary parent
symbol. This should unblock the `repeat_choice_seq_js` parser-boundary target without
broadening precedence rules or changing unrelated conflict behavior.

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
   auxiliary, resolve this intentional repeat ambiguity by keeping the shift and setting
   the shift action's `is_repetition` flag.
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

It misses the upstream same-parent-auxiliary case. In `repeat_choice_seq_js`, the reduce
production is `_entry -> identifier number_literal*`, so `lhs_is_repeat_auxiliary` is
false. But the conflicting items are all associated with the same auxiliary parent from
the hidden repeated `_entry` body. Upstream treats that as intentional repeat ambiguity
and marks the shift as repetition.

Local complication: `actions.ParseAction.shift` does not carry a repetition flag.
Zig chooses the action during resolution, then later attaches `.repetition = true` in
serialization. Therefore the fix has two required parts:

1. Resolution must choose the shift for same-auxiliary conflicts.
2. Serialization must mark the chosen shift action with `.repetition = true` for the
   same broader conflict class.

Implementing only one side is incomplete: choosing shift without repetition loses the
runtime flag, while marking repetition without resolving the conflict leaves the state
blocked.

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
- [x] If the helper returns true, return the shift action immediately.
- [x] Keep existing precedence behavior unchanged for non-auxiliary conflicts.
- [x] Add a focused `resolution.zig` test for the `repeat_choice_seq_js` shape:
  - an auxiliary parent production such as `_entry` with a completed reduce item;
  - a shift item from the same auxiliary parent on the same lookahead;
  - reduce production itself must have `lhs_is_repeat_auxiliary = false`;
  - assert the resolved action is the shift and the conflict is not left unresolved.
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
- [x] Ensure `attachRepetitionShiftMetadataAlloc` marks the chosen shift action with
  `.repetition = true` for the same conflict shape that resolution now resolves.
- [x] Add a focused serialization test mirroring the resolution fixture:
  - chosen shift on the conflict symbol;
  - same auxiliary parent;
  - reduce production is not itself repeat auxiliary;
  - assert `serialized.states[*].actions[*].repetition == true`;
  - assert `parse_action_list` also carries `.repetition = true`.
- [x] Add a negative serialization test for non-auxiliary common LHS or mixed LHS.

---

## Phase 4 — Pipeline Fixture Coverage

- [x] Add or reuse a small grammar fixture matching the `repeat_choice_seq_js` shape:

```text
source_file := REPEAT1(_entry)
_entry      := (identifier number_literal*) | (number_literal identifier+)
```

- [x] Run it through the existing grammar loader / prepare / parse-table pipeline in a
  focused test, not through the heavy compatibility harness.
- [x] Assert the serialized table is no longer blocked by unresolved shift/reduce
  decisions.
- [x] Assert at least one emitted parse action has `.repetition = true` for the relevant
  shift.
- [x] If an exact golden exists and would require unrelated EOF/golden churn, prefer a
  focused behavioral/assertion test over refreshing broad string goldens.

---

## Phase 5 — Plan and Gap Documentation

- [x] Update `ReWrite-4_1.md` checkboxes as phases are completed.
- [x] Update `GAPS_260425.md` or the relevant gap note to say the
  `repeat_choice_seq_js` same-auxiliary repeat conflict is no longer a missing
  algorithm once the focused tests pass.
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
