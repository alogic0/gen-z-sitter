# Gap Audit — gen-z-sitter vs tree-sitter (2026-05-01)

Generated from `docs/gap-check-task-260501.md` via direct source-code analysis
of both codebases. All numbers are from the JavaScript minimized comparison at
`.zig-cache/upstream-compare-javascript-runtime/local-upstream-summary.json`
unless noted otherwise.

**Reference point:** All of the following metrics now match between local and
upstream (minimized, `--minimize` flag):

| Field | Value |
|---|---|
| serialized_state_count | **1,870 / 1,870** |
| large_state_count | **387 / 387** |
| external_lex_state_count | **10 / 10** |
| token_count | **134 / 134** |
| corpus_samples | **matched** |

**Remaining diffs (all 6 are suspected_algorithm_gap):**

| Field | Local | Upstream | Delta |
|---|---|---|---|
| lex_function_case_count | 525 | 279 | +246 (+88%) |
| large_character_set_count | 0 | 3 | −3 |
| parse_action_list_count | 3,592 | 3,588 | +4 |
| keyword_lex_function_case_count | 201 | 200 | +1 |
| symbol_order_hash | mismatch | — | ordering differs |
| field_names_hash | mismatch | — | ordering differs |

---

## 1. Lex Emission Shape (525 vs 279 cases, 0 vs 3 large_character_set_count)

This is the largest remaining gap: local emits 88% more case entries in the
lex switch. The direct cause is that local emits 0 large character set
declarations while upstream emits 3. Each large character set collapses many
individual case branches into a single `set_contains()` call.

### What tree-sitter does

**Phase 1 — pre-computation (per-token, grammar-level):**
`/home/oleg/prog/tree-sitter/crates/generate/src/build_tables/build_lex_table.rs`
lines 96–129.

After building the main lex table, tree-sitter performs a **second pass** over
every grammar terminal. For each terminal `symbol`, it re-runs the NFA builder
as if that token were the only token in the grammar (`add_state_for_tokens` with
a single-element token set). It then inspects every lex state of the resulting
single-token table:

- Collects all `in_main_token` transitions (transitions that advance the lexer,
  not skip/separator transitions) and accumulates their character sets.
- If an individual `skip`-phase transition has > 8 ranges, adds it to
  `large_character_sets` with `None` as the associated symbol.
- If the accumulated `in_main_token` character set for this token has > 8 ranges,
  adds it to `large_character_sets` with `Some(symbol)`.

Duplicate sets are filtered. The result: **3 large character sets for JavaScript**,
each representing one token's full character class (typically Unicode identifier
ranges like `[a-zA-Z_$À-ʸ...]`).

**Phase 2 — approximate best-fit matching at emission:**
`/home/oleg/prog/tree-sitter/crates/generate/src/render.rs` lines 940–1025.

During lex function emission, for every transition whose `simplified_chars` has
≥ 8 ranges, tree-sitter does NOT require an exact match. It iterates the
pre-computed large character sets and finds the **best-fit** (the set whose
intersection with `simplified_chars` is largest, and whose symmetric difference
has the fewest total ranges). The emission then becomes:

```c
if (set_contains(ts_lex_character_set_1, 23, lookahead) ||
    lookahead == '+' || lookahead == '-') ADVANCE(5);
```

The `||` clause handles any characters in the transition that are NOT in the
matched large set ("additions"), and the caller also emits explicit `!` clauses
for characters in the large set that should NOT match ("removals").

This approximate matching is how 246 individual `case` branches are compressed
into 3 `set_contains` calls for JavaScript.

**Threshold:** `LARGE_CHARACTER_RANGE_COUNT = 8`
(build_lex_table.rs line 19).

### What gen-z-sitter does

`/home/oleg/prog/gen-z-sitter/src/lexer/emit_c.zig`

Gen-z-sitter has large character set pooling — `LargeCharacterSetIndex` — and
calls `emitLexFunctionWithResolverAlloc` (which uses the pre-computed index)
from `parser_c.zig` lines 251 and 264. So the infrastructure exists. The
two structural differences from tree-sitter are:

**Difference A — source of large sets (table states, not per-token grammar):**

`LargeCharacterSetIndex.initAlloc` (lines 101–121) scans the lex **table
states** (the final merged multi-token table) and collects transitions with
`ranges.len >= 8` as large sets. It does NOT re-evaluate each token separately.

In the final merged JavaScript lex table, the character classes for individual
tokens are fragmented across multiple transitions because the states are shared
by all tokens. A transition that, in a single-token table, would cover all
Unicode identifier ranges in one 8+ range set may be split into several smaller
transitions in the merged table — none of which individually crosses the 8-range
threshold. This is why local finds **0** large sets.

**Difference B — exact matching only, no approximate best-fit:**

`LargeCharacterSetIndex.find` (lines 141–143) calls `findInEntries` which uses
`rangeSetsEqual` (lines 222–232) — a byte-for-byte comparison of range arrays.
Even if local did find some large sets, it could only use them when a transition
had exactly that range array, never for approximate matches.

`isAdvanceMapTransition` (line 264–271) breaks on any `transition.skip=true`,
and the ADVANCE_MAP threshold condition (`range_count >= 8`) is structurally
equivalent to tree-sitter's. The ADVANCE_MAP gap is minor; the large character
set gap is the dominant cause.

### Root cause

Tree-sitter pre-computes large character sets by re-evaluating each token's NFA
**in isolation** (per-token single-symbol lex table), capturing each token's
full character class before other tokens' states merge and fragment it. It then
matches those pre-captured classes against final-table transitions
**approximately**, using a best-fit algorithm that tolerates additions and
removals.

Gen-z-sitter extracts large sets from the **already-merged** final lex table,
where the per-token character classes have been distributed and fragmented. No
transition in the merged table crosses the 8-range threshold for JavaScript, so
zero large sets are found.

### Estimate to close

**Effort: Medium**

1. After building the final lex table, iterate grammar terminals and re-evaluate
   each terminal's character class in single-token mode (or extract from the
   pre-build NFA/regex representation if available in the Zig pipeline).
2. Collect 8+ range sets with deduplication, producing the `large_character_sets`
   list with per-token identity.
3. At emission, replace `rangeSetsEqual` with the best-fit matching algorithm:
   compute intersection, additions, removals; pick the set with fewest correction
   ranges; emit `set_contains() || additions && !(removals)`.

**Impact:** `lex_function_case_count` 525 → ~279; `large_character_set_count`
0 → 3.

---

## 2. Symbol Ordering and Field Names Hash

The minimized comparison confirms that the **set** of symbols now matches
(token_count 134/134, no symbol_count diff). The `symbol_order_hash` and
`field_names_hash` mismatches are purely about **ordering**.

### What tree-sitter does

`/home/oleg/prog/tree-sitter/crates/generate/src/render.rs` lines 439–507.

`add_symbol_enum()` assigns IDs in **parse-table insertion order**:
- `Symbol::end()` → ID 0 (hardcoded).
- Then each symbol in `self.parse_table.symbols` in the order it was first
  encountered during LR(1) construction → IDs 1, 2, 3, …
- Aliases get subsequent IDs after all primary symbols.

The parse table is built by `build_parse_table.rs`. Symbols enter it in the
order of grammar rule expansion, starting from the start rule and following
production steps left-to-right, depth-first. This gives a grammar-derivation
order, not an alphabetical or type-grouped order.

Field names (`add_field_name_enum`, lines 509–516): extracted in grammar
production order during field-sequence collection.

### What gen-z-sitter does

`/home/oleg/prog/gen-z-sitter/src/parser_emit/parser_c.zig`
`collectEmittedSymbols()` (around line 1976).

Symbols are collected from `serialized.symbols`, augmented by scanning parse
states/actions/productions, then **sorted** by `emittedSymbolLessThan()`:
primary key is symbol type (`end`, `terminal`, `external`, `non-terminal`),
secondary key is index within that type. This produces a type-grouped order,
not the grammar-derivation order tree-sitter uses.

Field names are presumably sorted or collected in serialized-production order,
which also differs from tree-sitter's grammar-derivation order.

### Note on missing node types

The non-minimized comparison (without `--minimize`) shows 5 node types missing
in local (`property_identifier`, `statement_identifier`,
`shorthand_property_identifier*`, `static get`). These do NOT appear in the
minimized diff, suggesting they are present after minimization or that the
non-minimized comparison surface is different. The `symbol_order_hash` mismatch
in the minimized comparison is purely ordering, not a missing-symbol issue.

### Root cause

Gen-z-sitter sorts symbols by type group + index. Tree-sitter assigns IDs by
grammar-derivation / parse-table-insertion order. The two orderings produce
different hash values even when the symbol sets are identical.

### Estimate to close

**Effort: Small-to-Medium**

Change `emittedSymbolLessThan` to produce grammar-derivation order: emit
symbols in the order they first appear in parse-state item sets, which mirrors
tree-sitter's parse-table-insertion order. This requires threading the
construction order through the serialized representation, or sorting by first-
appearance in parse state 0's successors, then BFS order through successor
states.

**Impact:** `symbol_order_hash` and `field_names_hash` converge. Likely also
resolves the non-minimized node-type surface differences.

---

## 3. Parse Action List Residual (+4 entries, +1 keyword lex case)

### What tree-sitter does

`/home/oleg/prog/tree-sitter/crates/generate/src/render.rs`
`add_parse_action_list()`.

Action sequences per parse state are deduplicated into a shared list. States
sharing an identical action sequence reference the same list offset. Recovery
and accept actions are pooled: there is one `RECOVER()` entry that is reused,
and `ACCEPT_INPUT()` appears exactly once.

**JavaScript reference:** 3,588 entries.

### What gen-z-sitter does

`/home/oleg/prog/gen-z-sitter/src/parse_table/serialize.zig`
`buildSmallParseTableAlloc()`.

Deduplication by exact action-sequence equality is implemented and working
(the minimized state count matches). The +4 excess suggests either:

1. **Recovery actions not pooled:** Local may emit a `RECOVER` or
   `SHIFT_EXTRA(0)` entry per conflict site rather than sharing one pool entry.
2. **State 0 initialization overhead:** State 0 is the synthetic recovery state
   added in the JavaScript parity work (`Close JavaScript parser-table parity
   gate` commit). Its action entries might create 4 additional unique sequences
   not present in upstream because upstream's state 0 is constructed differently.
3. **Fragile terminal marker:** The `repetition: bool` and `extra: bool` flags
   on `SerializedAction` could cause sequences that would be equal without those
   flags to differ, preventing deduplication for 4 cases.

**Keyword lex case count (+1, 201 vs 200):**

The keyword lex function (`ts_lex_keywords`) has 201 cases locally versus 200
upstream. The most likely cause: one keyword lex state that upstream merges into
an adjacent state is kept separate locally. This may be a boundary state (the
initial or fallback state) that gen-z-sitter counts differently.

### Root cause

The +4 parse action entries and +1 keyword lex entry are small enough that they
likely trace to a single localized difference in state 0 or the recovery action
encoding, rather than a systematic algorithm gap. They require targeted logging
to isolate (compare exact action-list offsets between local and upstream).

### Estimate to close

**Effort: Small** (once the specific offending sequences are identified via
logging). The infrastructure for deduplication is correct; this is a precision
issue in a specific edge case.

---

## 4. Real-Grammar Promotion Assessment

### Current status

| Grammar | Local non-minimized states | Unresolved entries | Scope gate | Blocked boundary |
|---|---|---|---|---|
| Python | 1,034 | **0** | serialize_only | none |
| TypeScript | 5,388 | **0** | serialize_only | none |
| Rust | 2,660 | **0** | serialize_only | none |

**Key finding:** None of the three grammars are blocked by shift/reduce
conflicts. All have `unresolved_entry_count=0` and `blocked_boundary=null`.
The `emission.blocked=true` flag reflects the **scope gate**
(`parser_boundary_check_mode=serialize_only`), which is an intentional
boundary decision, not a construction failure.

### What is actually blocking promotion

The scope gate holds these targets at `serialize_only`, meaning they run load,
prepare, and serialize — but not `emit_parser_c`, `compile_smoke`, or
`compat_check`. Promotion requires:

1. Running a minimized `compare-upstream` for each grammar to verify whether
   the minimized local state count converges to upstream's reference count.
2. If it converges: lift the scope gate to `emit_parser_c` or `full_pipeline`.
3. If it does not converge: record the divergence ratio and decide whether it
   is explained by known gaps (lex case count, symbol ordering) or indicates a
   new construction problem.

**No conflict resolution work is needed.** The conflict resolution gap was
closed as part of the JavaScript parity work (`Close JavaScript parser-table
parity gate` commit includes `resolve action table with first sets context`
changes).

### Recommended promotion commands

```bash
# Python minimized compare (upstream reference: ~1,097 states):
zig build run -- compare-upstream --minimize \
  --output .zig-cache/upstream-compare-python \
  --tree-sitter-dir ../tree-sitter \
  compat_targets/tree_sitter_python/grammar.json

# TypeScript minimized compare (upstream reference: ~4,042 states):
zig build run -- compare-upstream --minimize \
  --output .zig-cache/upstream-compare-typescript \
  --tree-sitter-dir ../tree-sitter \
  compat_targets/tree_sitter_typescript/grammar.json

# Rust minimized compare (upstream reference: ~2,822 states):
zig build run -- compare-upstream --minimize \
  --output .zig-cache/upstream-compare-rust \
  --tree-sitter-dir ../tree-sitter \
  compat_targets/tree_sitter_rust/grammar.json
```

### Promotion recommendation

Pending minimized comparison results. If state counts converge (within 5% of
upstream after minimization), all three can move to `emit_parser_c` scope
immediately. If they diverge by more than 10%, investigate whether the lex
emission gap (Gap 1) is the cause before lifting the gate.

---

## 5. Priority Summary

| Rank | Gap | Evidence | Effort | Recommended action |
|---|---|---|---|---|
| **1** | Lex case count (525 vs 279) | `large_character_set_count=0` vs 3; 0 large set declarations in local parser.c vs 45 in upstream | Medium | Implement per-token NFA re-evaluation to pre-compute large sets; add approximate best-fit matching at emission |
| **2** | Symbol/field ordering | `symbol_order_hash` and `field_names_hash` mismatch despite symbol sets matching | Small-Medium | Change emitted symbol sort order from type-grouped to grammar-derivation (parse-table insertion) order |
| **3** | Parse action list +4 | 3,592 vs 3,588 entries; likely state-0 or recovery action edge case | Small | Add per-action-sequence logging to find the 4 non-deduplicating cases |
| **4** | Keyword lex +1 | 201 vs 200 keyword lex cases | Small | Investigate whether the boundary/fallback keyword state is being counted differently |
| **5** | Python/TypeScript/Rust promotion | 0 unresolved, serialize_only gate, no conflict blocker | Small (gate lift) | Run minimized compare-upstream for each; lift gate if state count converges |

### Closure order

Fixing Gap 1 (lex case count) will have the largest surface impact and will
also directly inform whether Gaps 3 and 4 are closed as side effects (lex state
merging changes may affect action list count). Gap 2 (symbol ordering) is
independent and can be done in parallel.

Gaps 3–4 are likely one or two small targeted changes once logging isolates
the specific sequences. Gap 5 is a measurement + gate-lift operation with no
algorithm change required.

---

## Appendix: Source Locations

### Tree-sitter (Rust)

| Component | File | Key lines |
|---|---|---|
| Large char set pre-computation | `crates/generate/src/build_tables/build_lex_table.rs` | 19 (threshold), 96–129 (per-token collection) |
| Large char set emission (best-fit) | `crates/generate/src/render.rs` | 940–1025 |
| ADVANCE_MAP emission | `crates/generate/src/render.rs` | 883–930 |
| Symbol ordering | `crates/generate/src/render.rs` | 439–507 |
| Action list deduplication | `crates/generate/src/render.rs` | 1470–1530 |

### Gen-z-sitter (Zig)

| Component | File | Key lines |
|---|---|---|
| Lex emission entry points | `src/lexer/emit_c.zig` | 26–46 |
| Large char set index (pre-computed) | `src/lexer/emit_c.zig` | 101–144 |
| Large char set scan (on-the-fly) | `src/lexer/emit_c.zig` | 156–216 |
| ADVANCE_MAP condition | `src/lexer/emit_c.zig` | 252–271 |
| Threshold constants | `src/lexer/emit_c.zig` | 6–7 |
| Symbol sort order | `src/parser_emit/parser_c.zig` | ~1976–2226 |
| Action list deduplication | `src/parse_table/serialize.zig` | ~1274–1430 |
| Scope gate / boundary check | `compat_targets/shortlist_report.json` | per-target `parser_boundary_check_mode` |

### Comparison artifacts

| Artifact | Path |
|---|---|
| Minimized JS comparison (primary) | `.zig-cache/upstream-compare-javascript-runtime/local-upstream-summary.json` |
| Local emitted parser.c | `.zig-cache/upstream-compare-javascript-runtime/local/parser.c` |
| Upstream emitted parser.c | `.zig-cache/upstream-compare-javascript-runtime/upstream/parser.c` |
| Compat shortlist | `compat_targets/shortlist_report.json` |

---

*Generated: 2026-05-01*
*Methodology: direct source-code reading of tree-sitter (Rust) and gen-z-sitter
(Zig); numbers cross-checked against `.zig-cache/upstream-compare-javascript-runtime/`.*
