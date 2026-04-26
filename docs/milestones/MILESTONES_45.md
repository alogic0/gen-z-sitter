# MILESTONES 45 — Parse Table Algorithm Convergence with tree-sitter

This milestone is about closing the algorithmic gap between gen-z-sitter's parse table
generator and the upstream tree-sitter implementation in `/home/oleg/prog/tree-sitter`.

It is not about lexer or scanner parity — those are covered by M43/M44.
It is specifically about the LR item-set construction, action table structure,
and conflict handling machinery inside `src/parse_table/`.

---

## The Divergence

Both codebases build LR(1) parse tables from the same kind of item sets.
The data structures are similar. The end goal is the same.
But three architectural decisions differ and have compounding downstream effects.

**Closure computation.** Tree-sitter precomputes, at builder initialization time,
the closure additions for each non-terminal: a list of `(item, fixed_lookaheads,
propagates_lookaheads)` tuples. `propagates_lookaheads` is true when the parent
item's lookahead tokens can reach through the non-terminal expansion (i.e., the
suffix α following the non-terminal in the parent production is nullable).
During state construction, the closure loop uses this precomputed table directly.

Gen-z-sitter instead expands items lazily at closure time and memoizes full
closed item sets in `ClosureResultCache`, keyed by the seed `ParseItemSet`
(items + lookaheads). The result is functionally equivalent but skips the
propagation-flag bookkeeping and pays for it in cache size and miss cost.

**Action table structure.** Tree-sitter represents each `(state, token)` entry
as `Vec<ParseAction>` — a list that can hold multiple actions simultaneously.
Shift/reduce conflicts are stored in the table; resolution happens in a
separate offline pass (`handle_conflict()`). Remaining ambiguities pass through
to the GLR runtime.

Gen-z-sitter resolves conflicts inline during state construction. Each
`(state, symbol)` entry holds a single resolved action. Unresolvable conflicts
fail serialization immediately. There is no way to represent or defer ambiguity.

**Conflict handling strategy.** Because tree-sitter's action entries are
multi-valued, it can apply precedence/associativity rules offline after the
full table is built and compare them against an `expected_conflicts` whitelist
declared in the grammar. Gen-z-sitter has no such whitelist and no post-build
resolution phase.

These three differences are layered: the offline conflict phase requires the
multi-action table, which in turn does not require the precomputed closure
(that is independent), but the precomputed closure is the right starting point
because it matches the upstream architecture exactly and prepares the IR for the
subsequent changes.

---

## Phase 1 — Precomputed Closure Additions

**What changes.**

Replace the `ClosureResultCache` + lazy expansion in `build.zig` with a
precomputed additions table following tree-sitter's `ItemSetBuilder`.

At initialization (once per grammar), for each non-terminal N, compute:

```
additions[N] = list of (ParseItem, fixed_lookaheads: SymbolSet, propagates_lookaheads: bool)
```

- `fixed_lookaheads` = FIRST(α) where α is the suffix after the first symbol
  in the parent production step (already available from grammar IR's first-sets)
- `propagates_lookaheads = true` iff α is entirely nullable

During closure: for each item whose cursor sits at non-terminal N, iterate
`additions[N]`. For each entry, merge `fixed_lookaheads` into the added item's
lookahead set; if `propagates_lookaheads`, also union in the parent item's
current lookahead set.

`ClosureResultCache` is removed. The precomputed approach makes memoization
unnecessary because the additions are context-free — they depend only on the
non-terminal, not on the full seed item set.

**Files.**

- `src/parse_table/build.zig` — remove `ClosureResultCache`, rewrite
  `transitiveClosure()` to walk the additions table
- `src/parse_table/item_set_builder.zig` — new file (or rename of existing
  partial builder) that holds the precomputed additions and exposes the
  closure function
- `src/ir/grammar_ir.zig` — verify FIRST set and nullable-suffix information
  is accessible to the builder

**Validation.**

The observable output — state count, action table entries — must be identical
before and after this phase for all current compat targets. Use
`compat_targets/shortlist_report.json` and `compat_targets/parser_boundary_profile.json`
as regression oracles. If the state counts and resolved actions match, the
rewrite is correct.

`CoarseTransitionSpec` and `closure_pressure_mode` are gen-z-sitter extensions
that sit on top of the closure algorithm. They survive this phase unchanged.

**Risk.** Medium. The memoization cache currently prevents expansion loops.
The replacement must carry its own fixed-point guarantee: keep a visited set
during closure iteration keyed by `(item_core, lookaheads)` and stop when no
new items are added.

---

## Phase 2 — Multi-action Table

**What changes.**

Change the action table representation so each `(state, symbol)` entry holds
a slice of `ParseAction` instead of a single resolved action.

```zig
// before
pub const ResolvedActionGroup = struct {
    symbol: SymbolRef,
    action: ParseAction,
};

// after
pub const ActionGroup = struct {
    symbol: SymbolRef,
    actions: []ParseAction,   // may hold shift + reduce simultaneously
};
```

During state construction, stop resolving conflicts inline. Instead, accumulate
all candidate actions into the slice and tag entries that have more than one
surviving action with a conflict marker. Precedence/associativity rules are
applied in Phase 3's offline pass, not here.

Serialization (`serialize.zig`) must encode multi-action entries. The most
direct representation is an `ambiguous` flag on serialized state entries plus
a side table of `(state_id, symbol_index) -> []action` for the conflicting
entries. The GLR runtime will eventually walk this table; for now it is just
present in the serialized form.

Parser emission (`parser_c.zig`, `parser_tables.zig`) must emit the
multi-action side table even if the current runtime does not yet use it.

**Files.**

- `src/parse_table/actions.zig` — change entry type
- `src/parse_table/resolution.zig` — remove inline conflict failure; collect
  candidates, apply only unambiguous precedence rules here
- `src/parse_table/serialize.zig` — add ambiguous entry encoding
- `src/parse_table/state.zig` — update `ParseState` action field types
- `src/parser_emit/parser_tables.zig` — emit multi-action side table
- `src/parser_emit/parser_c.zig` — add multi-action array to emitted C struct

**Implementation note.** Keep a `--strict-conflicts` build option (default on)
that fails serialization if any multi-action entry survives Phase 3 resolution.
This preserves the current deterministic guarantee for all compat targets and
keeps the test suite green while the new path is developed.

**Risk.** High. This change cascades through every layer from parse table to
emitted C. Develop behind a build flag (`-Dglr-table=true`) so the existing
path compiles and passes tests throughout.

---

## Phase 3 — Offline Conflict Resolution and `expected_conflicts`

**What changes.**

Add a post-build conflict resolution pass and support for the grammar-level
`expected_conflicts` annotation.

**Grammar-level annotation.**

```json
{
  "name": "my_grammar",
  "expected_conflicts": [["rule_a", "rule_b"]],
  ...
}
```

Add `expected_conflicts: [][]const []const u8` to `raw.RawGrammar`
(`src/grammar/raw_grammar.zig`) and thread it through
`grammar_ir.PreparedGrammar`.

**Post-build pass.**

Add `src/parse_table/conflict_resolution.zig`. After the full table is built:

1. For each `(state, symbol)` entry with multiple actions:
   - Apply dynamic precedence rules
   - Apply integer precedence rules
   - Apply named precedence and associativity rules
   - If one action survives: replace the slice with the single winner
   - If multiple survive: check whether this conflict appears in `expected_conflicts`
     - If yes: leave the multi-action entry (GLR path)
     - If no: emit an error (same behavior as today's inline failure)

2. Collect all `expected_conflicts` that were declared but never triggered
   (grammar annotations that refer to no actual conflict) and warn.

This keeps the current deterministic guarantee for all grammars that do not
use `expected_conflicts`. It adds a defined path for grammars that do.

**Files.**

- `src/grammar/raw_grammar.zig` — add `expected_conflicts` field
- `src/ir/grammar_ir.zig` — thread field through IR
- `src/grammar/parse_grammar.zig` — parse and validate the annotation
- new `src/parse_table/conflict_resolution.zig`
- `src/parse_table/pipeline.zig` — wire the post-build pass in after
  state construction and before serialization
- `src/parse_table/build.zig` — remove remaining inline conflict failures

**Risk.** Low–Medium. The change is mostly additive. The existing early-fail
path is replaced by a deferred check that produces the same error for the
same grammars (those without `expected_conflicts`). All current compat targets
should pass without modification.

---

## Phase 4 — State Minimization

**What changes.**

Add an optional post-construction state minimization pass following
tree-sitter's `minimize_parse_table()`.

After the full action table is built and conflicts resolved, merge pairs of
states that have:

1. Identical item set cores (same items ignoring lookaheads), and
2. Identical transition/action relationships (same successor state IDs
   and same actions for every symbol)

This is Hopcroft-style equivalence-class partitioning over the completed
action graph. States that start equivalent and whose successors are also
equivalent (transitively) are merged.

The result is a smaller table that recognizes exactly the same language.

**Files.**

- new `src/parse_table/minimize.zig`
- `src/parse_table/pipeline.zig` — wire minimization as an optional
  post-serialization step
- `src/cli/args.zig` — add `--minimize` flag to `GenerateOptions`
- `src/cli/command_generate.zig` — pass flag through

**Validation.**

A minimized table must:
- accept every input accepted by the unminimized table
- reject every input rejected by the unminimized table
- have state count ≤ original state count

Add a test that runs the same grammar through both paths and checks these
three properties using the behavioral harness.

**Risk.** Low. Purely additive. The minimization pass can be toggled off and
the existing output is unchanged when it is.

---

## Execution Order and Gates

```
Phase 1 (precomputed closure)
    independent of Phases 2–4
    gate: serialized state counts and actions unchanged for all compat targets

Phase 2 (multi-action table)
    requires: nothing from Phase 1, but Phase 1 should come first for clarity
    gate: --strict-conflicts path still passes full test suite

Phase 3 (offline resolution + expected_conflicts)
    requires: Phase 2 (needs multi-action table to exist)
    gate: all current compat targets pass without adding expected_conflicts

Phase 4 (state minimization)
    requires: Phases 1–3 complete or stable
    gate: behavioral harness equivalence test passes on all shortlist targets
```

Phase 1 is the cleanest starting point and can be reviewed independently.
Phase 2 is the architectural pivot. Phase 3 makes the new architecture useful
for real grammars. Phase 4 is an optimization that can wait.

---

## What This Does Not Cover

- GLR runtime in the generated parser (the table will encode ambiguity after
  Phases 2–3, but the C runtime will not yet walk multiple actions)
- Lexer-state integration (that is M44's scope)
- Scanner parity (ongoing separate track)
- Grammar-JS evaluation changes
