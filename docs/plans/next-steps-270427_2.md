# Next Steps — 2026-04-27 (rev 2)

Audit date: 2026-04-27.
Picks up from `next-steps-260427_1.md` after the M47 tree builder, incremental
PoC, and M46 GLR helper scaffolding have landed.

---

## Current State

### Done since `next-steps-260426.md`

- **M45 Phase 3** — expected-conflict reporting wired into CLI; unused declarations
  produce warnings; shift/reduce conflicts routed through `ExpectedConflictPolicy`;
  staged fixture covers an expected shift/reduce conflict.
- **M45 Phase 4** — bounded state minimization behind `--minimize`; behavioral
  equivalence gate; `zig build run-minimize-report`.
- **M47 tree builder** — `ParseNode` with byte ranges + `entry_state` + `reused`;
  value stacks in scanner-free `ParseVersion`; terminal push on shift; parent
  pop/build on reduce; `SimulationResult.accepted.tree` threaded out.
- **M47 incremental PoC** — `Edit` struct; `simulateIncremental` scanner-free entry
  point; old-subtree prefix reuse by matching `entry_state` + `start_byte`;
  `external_lex_state` guard in place; equivalence yield helper.
- **JSON compat target** — added and passing at full pipeline level.
- **Deferred grammar snapshots** — JavaScript (12 K states), Python, TypeScript
  (5.2 K states), Rust (2.8 K states) registered; all serialize correctly in
  non-strict mode; each is held at `emit_parser_c` boundary pending GLR loop.
- **M46 GLR helpers** — all six helper families emitted behind
  `GEN_Z_SITTER_ENABLE_GLR_LOOP`:
  - `TSGeneratedParseVersion` struct + bounded stack + init + `push_state` (line 476)
  - Parse table lookup + `ts_generated_goto_state` (line 513)
  - `TSGeneratedParseStep` + `ts_generated_apply_parse_action` (line 541)
  - `ts_generated_fork_unresolved_actions` + clone (line 665)
  - `ts_generated_condense_parse_versions` (line 694)
  - `ts_generated_step_parse_versions` (line 725)

### What remains in the emitted GLR loop

Two functional gaps prevent the GLR loop from producing correct parses:

**Gap A — Reduce does not pop the stack.**
`ts_generated_apply_parse_action` (line 556) accumulates `dynamic_precedence`
and fills the step struct for a reduce, but does not pop `child_count` states
from `version->stack` and does not push the goto state.
`ts_generated_step_parse_versions` (line 725) receives `TSGeneratedParseStepReduce`
and breaks — no stack mutation happens.

**Gap B — No outer lex loop.**
`byte_offset` exists on each version (line 483) but nothing updates it.
There is no function that: (1) lexes at each version's current offset, (2) drives
the step loop per lookahead, (3) handles the reduce chain before the next shift,
and (4) returns an accepted/rejected outcome with a consumed-byte count.

---

## Priority 1 — Complete the Emitted GLR Loop

### 1a. Reduce: stack pop + goto

In `writeGlrActionDispatch` (`parser_c.zig:541`), after the reduce accumulates
`dynamic_precedence`, also pop and goto:

```c
case TSParseActionTypeReduce:
  version->dynamic_precedence += action->reduce.dynamic_precedence;
  if (version->stack_len <= action->reduce.child_count) break;
  version->stack_len -= action->reduce.child_count;
  {
    TSStateId top = version->stack[version->stack_len - 1];
    TSStateId next = ts_generated_goto_state(top, action->reduce.symbol);
    if (next == 0) break;
    if (!ts_generated_version_push_state(version, next)) break;
  }
  step.status = TSGeneratedParseStepReduce;
  ...
```

The `child_count` from `TSParseAction.reduce` carries the production length. The
goto lookup reuses the already-emitted `ts_generated_goto_state`.

### 1b. Reduce drive loop per version

A single lookahead can trigger a chain of reduces before the next shift. The
per-version step must loop on `TSGeneratedParseStepReduce` before returning
to the outer loop:

```c
static TSGeneratedParseStep ts_generated_drive_version(
    TSGeneratedParseVersion *version, TSSymbol lookahead_symbol) {
  TSGeneratedParseStep step;
  do {
    step = ts_generated_parse_version_step(version, lookahead_symbol);
  } while (step.status == TSGeneratedParseStepReduce);
  return step;
}
```

Replace the `ts_generated_parse_version_step` call in `writeGlrVersionStepLoop`
with `ts_generated_drive_version`.

### 1c. Outer lex + byte_offset advance

Add `writeGlrMainParseFunction` emitting `ts_generated_parse`:

```c
bool ts_generated_parse(const char *input, uint32_t length,
                        uint32_t *out_consumed_bytes) {
  TSGeneratedParseVersionSet set;
  ts_generated_parse_versions_init(&set, 0);  /* start state */

  while (true) {
    /* lex once per unique byte_offset among active versions */
    /* simplified single-position variant for now: */
    TSGeneratedParseVersion *lead = NULL;
    for (uint16_t i = 0; i < set.count; i++) {
      if (set.versions[i].active) { lead = &set.versions[i]; break; }
    }
    if (!lead) return false;

    TSSymbol lookahead_symbol;
    uint32_t advance_bytes;
    if (lead->byte_offset >= length) {
      lookahead_symbol = ts_builtin_sym_end;
      advance_bytes = 0;
    } else {
      /* call ts_lex at lead->byte_offset */
      lookahead_symbol = ts_lex_symbol(input + lead->byte_offset,
                                       length - lead->byte_offset,
                                       &advance_bytes);
    }

    bool accepted = ts_generated_step_parse_versions(&set, lookahead_symbol);
    if (accepted) {
      *out_consumed_bytes = lead->byte_offset + advance_bytes;
      return true;
    }

    /* advance byte_offset for all versions that just shifted */
    bool any_active = false;
    for (uint16_t i = 0; i < set.count; i++) {
      if (set.versions[i].active) {
        set.versions[i].byte_offset += advance_bytes;
        any_active = true;
      }
    }
    if (!any_active) return false;
  }
}
```

**Note.** The initial prototype can assume all active versions are at the same
byte offset (valid for most non-ambiguous prefixes). Divergent-offset handling
(versions that reduced a different number of input bytes) is a follow-up.

**Files.**
`src/parser_emit/parser_c.zig` — extend `writeGlrActionDispatch` (1a),
add `writeGlrDriveVersionHelper` (1b), add `writeGlrMainParseFunction` (1c).
`src/parser_emit/compat.zig` — add `ts_lex_symbol` signature if needed.

**Gate.**
1. A small staged fixture with a resolved grammar (no `TSUnresolved` entries)
   passes through the GLR path and produces the same output as the single-action
   path.
2. A staged fixture with one unresolved shift/reduce conflict forks correctly and
   accepts on the intended version.
3. `zig build test` green with default (non-GLR) path unchanged.

---

## Priority 2 — Promote the Deferred Grammar Wave

The four deferred targets (JavaScript, Python, TypeScript, Rust) already
serialize with non-strict mode. They are held at `emit_parser_c` by a
compat-harness boundary check. Once the GLR loop passes its gate (Priority 1),
lift that boundary.

**Steps.**

1. In `src/compat/targets.zig`, update each deferred target's
   `parser_boundary_check_mode` from `serialize_only` to `full_pipeline` with
   `glr_loop: true` in emit options.

2. Run `zig build run-compat-target -Dcompat-target=tree_sitter_javascript_json
   -Dcompat-stop-after=emit_parser_c` and verify it compiles.

3. For each target that compiles: run `zig build test-compat-heavy` scoped to
   that target and verify the C links against tree-sitter's runtime library.
   Check parse result on the sample input.

4. Promote each target's `proof_scope` from `compile_smoke` to
   `full_runtime_link` once the parse produces a non-ERROR result on the sample.

5. For Bash and Haskell, verify the real external-scanner link still works through
   the GLR path (their grammars have no unresolved entries so the GLR loop should
   be a transparent no-op for them).

6. Refresh `shortlist_report.json`, `parser_boundary_probe.json`, and
   `shortlist_inventory.json`.

**Expected blockers.**

- JavaScript has ~12 K states. If construction time is too long for routine
  compat runs, add it to `test-compat-heavy` rather than the default suite.
- TypeScript at ~5 K states should fit the bounded suite.
- Python and Rust at ~2–3 K states should be fast enough for the default suite.

---

## Priority 3 — M47 Equivalence Tightening for Ambiguous Grammars

`next-steps-260427_1.md` Priority 2 notes:

> Tighten equivalence assertions for ambiguous grammars, where fresh and
> incremental parses can choose different valid tree shapes.

The current equivalence check (`430139b`) compares trees structurally. For
ambiguous grammars, a fresh parse and an incremental parse may choose different
but equally valid derivations when GLR forks diverge. The assertion must be
relaxed to compare **yield** (the sequence of terminal byte spans) rather than
tree shape when the grammar has unresolved entries.

**Steps.**

1. Add a `grammarHasUnresolvedEntries(prepared)` helper.
2. In `simulateIncremental`, if the grammar has unresolved entries: assert
   only that the fresh and incremental yields are identical (same terminal
   byte ranges in order), not that the tree shapes match.
3. Add a fixture: a small ambiguous grammar, input, edit, assertion that the
   yield matches.

**Files.** `src/behavioral/harness.zig`, new fixture in behavioral tests.

---

## Priority 4 — M46 T2: Error Recovery in Emitted Parser

**Prerequisite.** Priority 1 (GLR loop) must be complete and green.

The behavioral harness has two-stage error recovery (scan back for a recovery
state; skip one byte/token). The emitted `parser.c` produces a hard failure
on invalid input with no partial tree or error node.

**Steps.**

1. Add error recovery to `ts_generated_drive_version`:
   - When `ts_generated_parse_version_step` returns `TSGeneratedParseStepNoAction`:
     - Stage 1: scan backward through `version->stack` for a state that has a
       valid action for the current lookahead; if found, shrink `stack_len` to
       that depth, increment `version->error_count`.
     - Stage 2: if stage 1 fails, advance `byte_offset` by one and retry.
     - If both fail after a byte-limit: mark version inactive.

2. Track `error_count` per version (already in the version struct as `error_count`
   at line 483).

3. In `ts_generated_condense_parse_versions`, prune versions whose `error_count`
   exceeds the minimum active version's `error_count` by more than 3 (matching
   tree-sitter's threshold).

4. Test: a grammar that accepts `"(expr)"`, input `"(garbage)"`, assert the
   result contains an ERROR span but still accepts.

**Files.** `src/parser_emit/parser_c.zig` (extend drive loop and condense).

---

## Priority 5 — Extend Incremental to Scanner-Using Grammars

The current incremental proof (`simulateIncremental`) is scanner-free only —
it does not thread through the external-scanner callback path.

**Prerequisite.** Priorities 1–2 (GLR loop + deferred grammar promotion) must
be stable, because scanner-using grammars are the interesting incremental cases.

**Steps.**

1. Audit `simulateIncremental` entry point: identify which call sites in the
   harness use the external-scanner path vs. the scanner-free path.

2. Add `simulateIncrementalWithScanner` that passes a `ScannerCallbacks` pointer
   alongside the old tree and edit. On reuse, skip the scanner for reused states;
   on fresh parse at scanner states, invoke the scanner normally.

3. The critical invariant: if a reused subtree's `entry_state` has
   `external_lex_state != 0`, do not reuse it (the scanner may have side effects
   that affect later tokens). The `2977928` guard already covers this for the
   scanner-free path; verify it extends cleanly to the scanner path.

4. Test: `bracket_lang` grammar, input `"(())"`, append `"()"` to get `"(())()"`,
   assert the inner `"(())"` subtree is reused and only `"()"` is freshly parsed.

**Files.** `src/behavioral/harness.zig`, new bracket_lang incremental fixture.

---

## Deferred

| Item | Why deferred |
|---|---|
| `#pragma GCC optimize ("O0")` for large lex tables | No correctness impact; C compile time only |
| Public `TSTree` / `TSNode` ABI compatibility | Not needed until gen-z-sitter is used as a drop-in replacement |
| Multi-language included ranges | Requires basic incremental to be stable first |
| Full emitted-parser error-recovery with ERROR nodes | Needs Priority 4 as prerequisite |

---

## Execution Order

```
Priority 1 (GLR reduce + outer loop)
    ↓
Priority 2 (promote deferred grammar wave)     ← depends on P1
    ↓
Priority 3 (equivalence tightening)            ← independent, can overlap P2
Priority 4 (emitted error recovery)            ← depends on P1
    ↓
Priority 5 (scanner incremental)               ← depends on P1 + P2 stable
```

Priorities 1 and 3 can be worked in parallel. Priority 2 unlocks the
broadest visible impact (four real-world grammars promoted). Priority 4
provides a correctness guarantee for invalid-input handling. Priority 5
completes the incremental proof for the most important grammar class.
