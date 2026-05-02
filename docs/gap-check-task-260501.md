# Task: Gap Analysis — gen-z-sitter vs tree-sitter (rev 3, 2026-05-01)

Supersedes `docs/gap-check-task-260428.md`.
That document tracked 14 open audit items and the initial JavaScript parse-table
convergence work. All 14 items are now closed. This revision covers the remaining
emission-shape gaps, the next real-grammar promotion wave, and the deferred
measurement-gated work now that JavaScript parity is a concrete reference point.

---

## Context

`~/prog/gen-z-sitter` is a Zig reimplementation of the tree-sitter parser
generator. Primary reference: `~/prog/tree-sitter`.

**What changed since 260428:**

- JavaScript minimized state count reached parity: **1,870 / 1,870**.
- External lex state count reached parity: **10 / 10**.
- Large state count reached parity: **387 / 387**.
- JavaScript corpus samples: **matched** (compare-upstream corpus runner passes).
- All 14 `audit_gap_status` items from the 260428 audit are now **closed**:
  `primary_state_ids_emitted`, `emitted_error_cost_pruning`,
  `per_target_build_config_loaded`, `haskell_closure_pressure_configured`,
  `scanner_state_glr_condensation`, `scanner_aware_incremental_sample`,
  `generic_runtime_proof_config`, `behavioral_error_cost_parity`,
  `max_version_count_overflow`, `recovery_skip_and_relex`,
  `recovery_extend_error_span`, `incremental_reuse_guards`,
  `expected_conflict_equivalence`, `complex_scanner_promotion`.
- Python (1,034 states), TypeScript (5,388 states), and Rust (2,660 states)
  all complete construction with zero unresolved entries; emission boundary
  gates are the only remaining block.

**Current JavaScript minimized comparison (`--minimize`) residual diffs:**

| Field | Local | Upstream | Classification |
|---|---|---|---|
| language_version | 15 | 14 | known_unsupported_surface |
| symbol_order_hash | mismatch | — | suspected_algorithm_gap |
| field_names_hash | mismatch | — | suspected_algorithm_gap |
| parse_action_list_count | 3,592 | 3,588 | suspected_algorithm_gap (+4) |
| **lex_function_case_count** | **525** | **279** | **suspected_algorithm_gap (2×)** |
| keyword_lex_function_case_count | 201 | 200 | suspected_algorithm_gap (+1) |
| **large_character_set_count** | **0** | **3** | **suspected_algorithm_gap** |

Evidence directory: `.zig-cache/upstream-compare-javascript-runtime/`.

---

## Area 1 — Lex Function Case Count (Active Gap, Priority 1)

Local emits 525 lex-function case entries versus upstream's 279. This 2× gap
is the largest remaining emission-shape mismatch. Upstream uses `ADVANCE_MAP`
macro blocks for dense character ranges and represents them as
`large_character_set_count = 3` rather than individual cases.

```bash
# Count switch cases in emitted lex function:
grep -c "case 0x\|ADVANCE\|SKIP" \
  .zig-cache/upstream-compare-javascript-runtime/local/parser.c | head -5

# Count in upstream:
grep -c "case 0x\|ADVANCE\|SKIP" \
  .zig-cache/upstream-compare-javascript-runtime/upstream/parser.c | head -5

# Where ADVANCE_MAP is generated in upstream:
grep -n "ADVANCE_MAP\|large_character_set\|add_character_set" \
  ~/prog/tree-sitter/crates/generate/src/render.rs | head -20

# Where local would emit large character sets:
grep -n "ADVANCE_MAP\|large_char\|LargeChar\|dense" \
  ~/prog/gen-z-sitter/src/lexer/emit_c.zig | head -20

# What transitions produce the extra cases:
grep -n "transition_count\|range_count\|LargeRange\|large_range" \
  ~/prog/gen-z-sitter/src/lexer/build.zig \
  ~/prog/gen-z-sitter/src/parse_table/serialize.zig | head -20
```

Specific questions:

- What is the upstream threshold for switching from per-character `case`
  statements to an `ADVANCE_MAP` block? (Check `render.rs` around
  `add_character_set` and the `large_character_set` predicate.)
- Does `emit_c.zig` have a code path for emitting `ADVANCE_MAP`, or is it
  completely absent?
- Are the extra 246 local cases in identifier-class ranges (a-z, A-Z, 0-9,
  Unicode) that upstream consolidates via `ADVANCE_MAP`?
- Would implementing `ADVANCE_MAP` emission close the `large_character_set_count`
  gap simultaneously?

---

## Area 2 — Symbol Ordering and Field Names Hash (Active Gap, Priority 2)

`symbol_order_hash` and `field_names_hash` differ between local and upstream
despite state count and token count now matching. These hashes cover the order
in which symbols and field names appear in the emitted tables.

```bash
# Extract symbol list from local emitted parser.c:
grep "^\s*\[" \
  .zig-cache/upstream-compare-javascript-runtime/local/parser.c \
  | grep "ts_symbol_names\|SYMBOL_" | head -20

# Extract symbol list from upstream parser.c:
grep "^\s*\[" \
  .zig-cache/upstream-compare-javascript-runtime/upstream/parser.c \
  | grep "ts_symbol_names\|SYMBOL_" | head -20

# How upstream orders symbols (build_tables then render):
grep -n "symbol_order\|sort.*symbol\|push.*sym\|symbols.*sort" \
  ~/prog/tree-sitter/crates/generate/src/build_tables/build_parse_table.rs \
  ~/prog/tree-sitter/crates/generate/src/render.rs | head -20

# How local orders symbols:
grep -n "symbol_order\|sort.*symbol\|SymbolOrder\|addSymbol" \
  ~/prog/gen-z-sitter/src/parse_table/serialize.zig \
  ~/prog/gen-z-sitter/src/parser_emit/parser_c.zig | head -20

# Field name ordering in local vs upstream:
diff \
  <(grep "ts_field_names" \
    .zig-cache/upstream-compare-javascript-runtime/local/parser.c | head -40) \
  <(grep "ts_field_names" \
    .zig-cache/upstream-compare-javascript-runtime/upstream/parser.c | head -40)
```

Specific questions:

- Does upstream sort symbols by (kind, grammar-rule-order) or by first
  appearance in the parse table?
- Are the missing upstream node types (`property_identifier`,
  `statement_identifier`, `shorthand_property_identifier*`, `static get`)
  related to alias handling rather than symbol ordering? These appear in the
  non-minimized comparison's `node_types_diff`.
- Do field name mismatches come from ordering or from missing/extra fields?
- Would closing the symbol-order gap also close the `node_types_hash` diff?

---

## Area 3 — Parse Action List Residual (+4 entries, Priority 3)

Local emits 3,592 parse action list entries versus upstream's 3,588 (+4).
The keyword lex case count is 201 versus upstream's 200 (+1). Both are small
enough that they may trace to a single shared cause.

```bash
# Compare action list sizes by state in the two parsers:
diff \
  <(grep -c "ts_parse_actions" \
    .zig-cache/upstream-compare-javascript-runtime/local/parser.c) \
  <(grep -c "ts_parse_actions" \
    .zig-cache/upstream-compare-javascript-runtime/upstream/parser.c)

# Look for the +4 in action entries — check shift_extra or accept entries:
grep -n "SHIFT_EXTRA\|ACCEPT_INPUT\|RECOVER\|shift_extra" \
  ~/prog/gen-z-sitter/src/parse_table/serialize.zig | head -20

# Keyword lex table entry count:
grep -n "keyword_lex\|ts_lex_keywords\|KEYWORD" \
  .zig-cache/upstream-compare-javascript-runtime/local/parser.c | wc -l
grep -n "keyword_lex\|ts_lex_keywords\|KEYWORD" \
  .zig-cache/upstream-compare-javascript-runtime/upstream/parser.c | wc -l
```

Specific questions:

- Do the 4 extra action entries correspond to `SHIFT_EXTRA` or `ACCEPT_INPUT`
  rows that upstream deduplicates? Or are they in a specific state family
  (error/recovery states)?
- Does the +1 keyword lex case correspond to the same alias or inline variable
  that causes the +4 parse actions?

---

## Area 4 — Real-Grammar Promotion Wave (Python, TypeScript, Rust)

Python (1,034 states, 0 unresolved), TypeScript (5,388 states, 0 unresolved),
and Rust (2,660 states, 0 unresolved) all complete construction cleanly but
are held at `coarse_serialize_only`. The next step is to run minimized
compare-upstream for each and record whether state counts converge, then
decide which targets can advance to a higher proof scope.

```bash
# Run minimized comparison for Python:
zig build run -- compare-upstream --minimize \
  --output .zig-cache/upstream-compare-python \
  --tree-sitter-dir ../tree-sitter \
  compat_targets/tree_sitter_python/grammar.json 2>&1 \
  | grep -E "states=|state_count|unresolved|blocked"

# Run minimized comparison for TypeScript (tsx variant):
zig build run -- compare-upstream --minimize \
  --output .zig-cache/upstream-compare-typescript \
  --tree-sitter-dir ../tree-sitter \
  compat_targets/tree_sitter_typescript/grammar.json 2>&1 \
  | grep -E "states=|state_count|unresolved|blocked"

# Run minimized comparison for Rust:
zig build run -- compare-upstream --minimize \
  --output .zig-cache/upstream-compare-rust \
  --tree-sitter-dir ../tree-sitter \
  compat_targets/tree_sitter_rust/grammar.json 2>&1 \
  | grep -E "states=|state_count|unresolved|blocked"

# Upstream reference state counts (from parser_boundary_probe or their parsers):
grep -E "python|typescript|rust" \
  compat_targets/parser_boundary_probe.json 2>/dev/null | head -20
```

Specific questions:

- For each of Python, TypeScript, and Rust: does the minimized local state
  count match upstream's? If not, what is the ratio and does it resemble the
  pre-fix JavaScript ratio (indicating a known algorithm gap) or a different
  pattern?
- Are there unresolved entries after minimization, or does the construction
  succeed cleanly?
- Can any of the three be promoted from `coarse_serialize_only` to
  `serialize_only` or `emit_parser_c` based on the minimized comparison result?
- Does TypeScript (5,388 non-minimized) have a substantially different
  convergence behavior than JavaScript, given it uses JSX/TSX extensions?

---

## Area 5 — Deferred Measurement-Gated Items

Three items are in `audit_gap_status.deferred_measurement_gated`:
`dag_stack_replacement`, `symbol_set_key_compression`,
`emitted_c_shape_tuning`. These were deferred until measurements showed
they were the active bottleneck.

```bash
# Current wall-clock for JavaScript full minimized comparison:
time zig build run -- compare-upstream --minimize \
  --output .zig-cache/upstream-compare-javascript-perf \
  --tree-sitter-dir ../tree-sitter \
  compat_targets/tree_sitter_javascript/grammar.json 2>&1 | tail -5

# Memory: symbol set allocation stats (from parse construct profile):
cat .zig-cache/upstream-compare-javascript-runtime/local-upstream-summary.json \
  | python3 -c "
import json, sys
d = json.load(sys.stdin)
cp = d['local'].get('parse_construct_profile', {})
for k in ('symbol_set_init_empty_count','symbol_set_clone_count',
          'symbol_set_free_count','symbol_set_alloc_bytes','symbol_set_free_bytes'):
    print(k, cp.get(k,'?'))
"

# Check if symbol_set is the dominant cost path:
cat .zig-cache/upstream-compare-javascript-runtime/local-upstream-summary.json \
  | python3 -c "
import json, sys
d = json.load(sys.stdin)
cp = d['local'].get('parse_construct_profile', {})
for k,v in cp.items():
    if 'ns' in k:
        print(k, v)
"
```

Specific questions:

- For the current JavaScript build, what fraction of parse-construction time
  is in `collect_transitions_ns` vs `build_actions_ns` vs `detect_conflicts_ns`?
- What is the peak RSS for TypeScript construction? Does it stay under the
  memory budget defined in Phase 6 of the parity plan?
- Is `symbol_set_alloc_bytes` the dominant allocator load, or is it
  dwarfed by item-set or hash-map allocations?
- Are any of the three deferred items now the active bottleneck, or do
  Python/TypeScript/Rust construction times stay acceptable without them?

---

## Area 6 — Release Boundary and Documentation (Phase 7)

The parity plan's Phase 7 is pending. The evidence now supports a concrete
release boundary statement that was not possible in 260428.

```bash
# Current compat summary:
python3 -c "
import json
with open('compat_targets/shortlist_report.json') as f:
    d = json.load(f)
agg = d['aggregate']
print('passed_within_current_boundary:', agg['passed_within_current_boundary'])
print('blocked_targets:', agg['blocked_targets'])
print('deferred_measurement_gated:', list(d['audit_gap_status']['deferred_measurement_gated'].keys()))
"

# What is still claiming to be blocked at the boundary:
python3 -c "
import json
with open('compat_targets/shortlist_report.json') as f:
    d = json.load(f)
for r in d['results']:
    bb = r.get('blocked_boundary')
    if bb:
        print(r['display_name'], ':', list(bb.keys()) if isinstance(bb, dict) else bb)
"

# Where README and HOWTO mention current limitations:
grep -n "not.*support\|deferred\|scanner\|external.*token\|limit" \
  README.md HOWTO/*.md 2>/dev/null | head -20
```

Specific questions:

- Which grammars can now be listed as "supported at full-pipeline" vs
  "supported at parser-only" vs "not yet supported"?
- Does the current README accurately describe the `scanner_external_scanner`
  boundary, or does it still understate what the scanner wave has achieved?
- Are the `Repeat Choice Seq (JS)` and `Parse Table Conflict (JSON)` blocked
  boundaries cosmetic (intentional fixtures) or real gaps that need a note?
- What is the correct user-facing description of the GLR loop limitation
  (`GEN_Z_SITTER_ENABLE_GLR_LOOP` behind a compile flag)?

---

## How to Examine the Code

Run in order. Each step is independent.

```bash
# 1. Reproduce the current residual diffs:
zig build run -- compare-upstream --minimize \
  --output .zig-cache/upstream-compare-javascript-verify \
  --tree-sitter-dir ../tree-sitter \
  compat_targets/tree_sitter_javascript/grammar.json 2>&1 \
  | grep -E "local|upstream|classification" | grep -v "known_unsup"

# 2. Measure lex case gap:
grep -c "case 0x" \
  .zig-cache/upstream-compare-javascript-runtime/local/parser.c
grep -c "case 0x" \
  .zig-cache/upstream-compare-javascript-runtime/upstream/parser.c

# 3. Check large character set emission in local lexer:
grep -n "ADVANCE_MAP\|large.*char\|dense.*range" \
  ~/prog/gen-z-sitter/src/lexer/emit_c.zig

# 4. All tests pass:
zig build test 2>&1 | tail -5

# 5. Compat shortlist summary:
zig build run -- shortlist 2>&1 | tail -10
```

---

## Output Format

Write a report with these sections:

### 1. Lex Emission Shape Gap
Root cause of 525 vs 279 lex cases. Is `ADVANCE_MAP` the fix, or is there
also a state-merging gap? Estimate effort to close.

### 2. Symbol and Field Ordering
Explain `symbol_order_hash` and `field_names_hash` mismatches.
Are the missing node types (`property_identifier`, etc.) a consequence
or a separate issue?

### 3. Parse Action and Keyword Lex Residual
Identify the source of the +4 action list entries and +1 keyword lex case.
Are they a shared root cause?

### 4. Real-Grammar Promotion Assessment
Table: grammar | non-minimized states | minimized states | upstream states | gap% | recommended next scope.
Flag if any show a pattern different from the pre-fix JavaScript ratio.

### 5. Deferred Item Status
For each deferred item (`dag_stack_replacement`, `symbol_set_key_compression`,
`emitted_c_shape_tuning`): active bottleneck / not yet needed / now needed.
Support with timing or allocation numbers.

### 6. Release Boundary Summary
One paragraph describing what the generator now supports, what is behind
a deferred gate, and what is explicitly out of scope. Suitable for use
in a README "current status" section.

---

## Scope

Include:
- Lex function emission shape and `ADVANCE_MAP` gap
- Symbol/field ordering and node-type surface alignment
- Parse action list and keyword lex residual (+4, +1)
- Python, TypeScript, Rust minimized state comparison and promotion decision
- Deferred measurement-gated item status vs. current workloads
- Release boundary documentation accuracy

Exclude:
- JavaScript corpus expansion beyond the three curated samples (deferred)
- External scanner grammars beyond current proof coverage (deferred)
- Grammar.js evaluation (Node.js subprocess; out of scope)
- Public TSTree/TSNode ABI compatibility (not yet a project goal)
- Performance rewrites not supported by current measurements
