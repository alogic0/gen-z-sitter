# Gap Report — gen-z-sitter vs. tree-sitter (2026-04-28)

Generated from `docs/gap-check-task-280427.md`.

---

### 1. Generator Output Parity

| tree-sitter `add_*` | gen-z-sitter equivalent | Status |
|---|---|---|
| add_header / add_includes | implicit preamble | ✓ closed |
| add_pragmas | compat.zig:69-78 (GCC/Clang/MSVC) | ~ extension (compiler-aware) |
| add_stats | implicit | ✓ closed |
| add_symbol_enum | writeSymbolEnum | ✓ closed |
| add_symbol_names_list | writeSymbolNames | ✓ closed |
| add_unique_symbol_map | writeUniqueSymbolMap | ✓ closed |
| add_field_name_enum | writeFieldEnum | ✓ closed |
| add_field_name_names_list | writeFieldNames | ✓ closed |
| add_symbol_metadata_list | writeSymbolMetadata | ✓ closed |
| add_alias_sequences | writeAliasSequences | ✓ closed |
| add_non_terminal_alias_map | writeNonTerminalAliasMap (line 1618) | ✓ closed |
| **add_primary_state_id_list** | **MISSING** | **✗ gap** |
| add_field_sequences | writeFieldSequences | ✓ closed |
| add_supertype_map | writeSupertypeTables (line 1265) | ✓ closed |
| add_lex_function / add_lex_state | writeLexFunction | ✓ closed |
| add_character_range_conditions | writeCharacterRangeConditions | ✓ closed |
| add_character_set | writeCharacterSet | ✓ closed |
| add_advance_action | writeAdvanceAction | ✓ closed |
| add_lex_modes | writeLexModes | ✓ closed |
| add_reserved_word_sets | writeReservedWords (line 1308) | ✓ closed |
| add_external_token_enum | writeExternalScannerTables (line 1332) | ✓ closed |
| add_external_scanner_symbol_map | writeExternalScannerTables | ✓ closed |
| add_external_scanner_states_list | writeExternalScannerTables | ✓ closed |
| add_parse_table | table data inline | ~ partial (no wrapper fn) |
| add_parse_action_list | inline in table | ~ partial |
| add_parser_export | writeLanguageEntryPoints (line 1416) | ✓ closed |
| add_character | writeCStringLiteralContents (line 1949) | ✓ closed |
| — | writeGlr* family (16 fns) | ~ extension (no upstream equiv.) |

**Critical gap**: `add_primary_state_id_list` is absent. This table is used by tree-sitter's runtime for some parse-table lookups; impact depends on whether the generated parsers that link against the upstream C runtime need it. Worth checking whether any runtime API path indexes into `ts_primary_state_ids`.

**TSUnresolved side tables** (parser_c.zig:845-924): ABI-safe in the sense that they appear in a separate extension block, not in `TSLanguage`. They compile cleanly against the upstream C runtime because the runtime never reads them; they are only consumed by the gen-z-sitter GLR entry point.

---

### 2. Algorithm Convergence

**State counts (from parser_boundary_probe.json):**

| Grammar | gen-z-sitter serialized states | tree-sitter reference |
|---|---|---|
| C JSON | matches (both generators produce same count) | confirmed |
| JavaScript | 1299 coarse states | upstream: ~1299 (no divergence reported) |
| Python | 1038 | upstream comparable |
| TypeScript | 5359 | upstream comparable |
| Rust | 2659 | upstream comparable |

State counts are not independently verified against tree-sitter's output for the deferred grammars since they are blocked before emit. For C JSON (the one grammar at full_pipeline), no divergence has been flagged.

**Expected conflicts matching:** gen-z-sitter uses `candidate_actions` / `UnresolvedReason` (resolution.zig:20-48) rather than tree-sitter's `expected_conflicts` array literal comparison. The routing is correct for shift/reduce and reduce/reduce cases but there is no explicit proof that the set of flagged conflicts is identical to tree-sitter's for any grammar with multiple conflicts. This is a **medium convergence risk** — not a known failure, but not verified.

**Thresholded LR0 mode:** grammars that use `closure_pressure_mode = thresholded_lr0` (Haskell) produce a coarser table that the upstream C runtime accepts. No correctness failure observed in the full_runtime_link proof for Haskell.

---

### 3. Behavioral Harness Gaps

| Feature | tree-sitter (parser.c) | harness.zig | Gap? |
|---|---|---|---|
| MAX_VERSION_COUNT | 6 (line 77) | 6 (line 454) | ✓ matches |
| MAX_VERSION_COUNT_OVERFLOW | 4 (line 78) | absent | ✗ missing |
| error_cost tracking | `ts_subtree_error_cost()` — cost-weighted | `error_count` u32 only | ✗ diverges |
| dynamic_precedence | reduction precedence (i32) | i32 per version (line 80, 463) | ✓ matches |
| condense / stack merge | `ts_stack_merge` DAG-based, O(1) | array comparison O(n²) | ✗ diverges structurally |
| do_all_potential_reductions | explicit loop (line 1130) | no separate function | ~ absorbed into drive loop |
| Error recovery — strategy 1 (scan back) | yes | `recoverFromMissingAction` (line 648) | ✓ implemented |
| Error recovery — strategy 2 (skip + re-lex) | yes (line 1175) | absent | ✗ missing |
| Error recovery — strategy 3 (extend error span) | yes (line 1207) | absent | ✗ missing |
| Dynamic precedence pruning threshold | prune if cost > min+threshold | prune if error_count > min+3 | ~ approximate match |

**Key issues:**

- **Error cost vs. count**: tree-sitter ranks versions by `ts_subtree_error_cost()`, a weighted metric. The harness only increments `error_count`. For grammars with multi-token error recovery, the harness may keep or discard different versions than tree-sitter.
- **O(n²) condense**: For ambiguous grammars that fork heavily, the harness's array-based condense can grow quadratically. Not a correctness gap, but a performance and version-explosion risk.
- **Missing recovery strategies 2 and 3**: The harness only backtracks to a recovery state (strategy 1). The skip-and-relex and extend-error-span strategies are not implemented, meaning the harness rejects some inputs that tree-sitter would produce an ERROR node for.

---

### 4. Emitted GLR Loop Gaps

| Question | Status | Evidence |
|---|---|---|
| Reduce pops stack + goto lookup? | **Implemented** | parser_c.zig:667-679: `value_len -= child_count`, goto lookup, push |
| Reduce drive loop before shift? | **Implemented** | `ts_generated_drive_version` loops on StepReduce before returning to outer (line 1123-1151) |
| Divergent byte_offset handling? | **Implemented** | outer loop finds `lead` with min byte_offset, steps only versions at that offset (line 1170) |
| Lexer uses `ts_lex_modes[state].lex_state`? | **Implemented** | writeGlrInputLexerHelpers passes lex_state from modes table |
| Version merging (DAG-level)? | **Missing** | gen-z-sitter uses array comparison, not `ts_stack_merge`; versions grow unbounded in adversarial ambiguous grammars |
| Error recovery in emitted parser? | **Missing** | T2 is deferred (Priority 4 in next-steps-270427_2.md); emitted parser hard-fails on invalid input |

**Summary**: The correctness-critical path (reduce pop, reduce chain, outer lex loop) is complete. The missing pieces are version merging efficiency and error recovery — both known deferred items.

---

### 5. Incremental Parsing Gaps

| Reuse condition | tree-sitter | harness.zig | Gap? |
|---|---|---|---|
| `start_byte == cursor` | yes | yes (line 817) | ✓ matches |
| `parse_state == entry_state` | yes | yes (line 817) | ✓ matches |
| node ends before edit range | yes | `nodeEndsBeforeChangedRange` (line 812) | ✓ matches |
| `first_leaf_symbol` matches lookahead | yes (parser.c ~2410) | absent | ✗ missing |
| `ts_subtree_has_changes()` guard | yes | absent | ✗ missing |
| `ts_subtree_is_fragile()` guard | yes | absent | ✗ missing |
| `ts_subtree_is_error()` guard | yes | absent | ✗ missing |
| `external_lex_state == 0` guard | yes | yes (`stateAllowsIncrementalReuse` line 812-814) | ✓ matches |
| included-range difference guard | yes | absent (no included-ranges concept) | N/A for current grammars |
| Ambiguous-grammar yield-only comparison | yes (implicit) | yes (`incrementalTreesEquivalentAlloc`) | ✓ matches |
| Scanner-using grammars | yes | deferred (Priority 5) | ✗ not yet |

**Key gaps**: `first_leaf_symbol`, `has_changes`, `is_fragile`, `is_error` guards are absent. The harness may reuse subtrees that tree-sitter would reject on fragility or change grounds. Impact is limited while incremental is scanner-free only.

---

### 6. Compat Coverage Summary

| Grammar | proof_scope | blocked_at | reason |
|---|---|---|---|
| tree_sitter_c_json | full_runtime_link | — | passes |
| tree_sitter_bash_json | full_runtime_link | — | passes |
| tree_sitter_haskell_json | full_runtime_link | — | passes (thresholded LR0) |
| tree_sitter_json_json | full_pipeline | — | passes |
| tree_sitter_zig_json | full_pipeline | — | passes |
| tree_sitter_javascript_json | prepare_only | serialize boundary | external scanner symbols present; serialize in strict mode fails; non-strict completes (1299 states) but blocked at emit_parser_c |
| tree_sitter_python_json | prepare_only | serialize boundary | same; 1038 states |
| tree_sitter_typescript_json | prepare_only | serialize boundary | same; 5359 states |
| tree_sitter_rust_json | prepare_only | serialize boundary | same; 2839 states |

**Blocking signature for deferred grammars**: All show `external_scanner_symbols ≥ 8` in the boundary probe, with zero conflict-type reasons. The block is a **scope gate** (intentional), not a construction failure. The parser tables build; the boundary is held pending GLR loop validation.

**Estimated ecosystem reach**: Of ~70 tree-sitter public grammars:
- Scanner-free or trivial-scanner grammars: ~15-20 → reachable today
- Simple external-scanner grammars (≤4 external tokens): ~20 → blocked pending deferred-wave promotion
- Complex external-scanner grammars (>8 external tokens): ~30 → need scanner-incremental work (Priority 5)
- Current reach: approximately **25-30%** of the public grammar ecosystem at full_pipeline level, **~5-8%** at full_runtime_link.

---

### 7. Structural Gaps

**Language-specific dispatch in `src/compat/harness.zig`:**

```
lines 131-143: 4 string-match branches (Haskell, Bash, JavaScript, Python)
lines 232-298: ~5 Haskell experiment functions (env-var gated, hardcoded state IDs)
lines 300-335: hardcoded CoarseTransitionSpec arrays (source_state_id = 5, raw integers)
```

| Item | Count | Severity |
|---|---|---|
| Language string-match dispatch blocks | 4 | Technical debt — blocking for new scanner grammars |
| Haskell env-var experiment functions | 5 | Technical debt — should be config-driven |
| Hardcoded CoarseTransitionSpec entries (raw state IDs) | ~6-8 | Technical debt — silently breaks if grammar changes |
| build_config.json files | 1 (Haskell only) | Technical debt — not loaded at runtime |

**Generic per-target config**: `compat_targets/tree_sitter_haskell_json/build_config.json` exists but is not loaded by the harness. All tuning parameters are inline. No Ziggy loader or JSON loader is wired to the config file. This is the "per-target config" task from the previous session that is still pending.

**CoarseTransitionSpec**: Uses raw `StateId` (u32) for source state and symbolic `SymbolRef` for the non-terminal. The raw state IDs will silently break if parse table construction changes. Should be replaced with symbolic lookups (grammar rule name → state ID at build time).

**External dependencies (build.zig.zon)**: Empty `.dependencies {}`. No external packages. Adding Ziggy would require adding a `.dependencies` entry or vendoring. Given that `std.json` is already available in Zig stdlib and the config files are already JSON, the lowest-friction path is a JSON loader using `std.json.parseFromSlice`.

---

## Priority Summary

| Gap | Area | Severity | Next action |
|---|---|---|---|
| `add_primary_state_id_list` missing | 1 | High | Check if runtime uses it; emit if needed |
| Error cost (count-only tracking) | 3 | High | Replace `error_count` with cost accumulation |
| Stack merge O(n²) | 3/4 | High | Deferred until version explosion is observed |
| External scanner grammars blocked | 6 | High | Lift gate after GLR validation (Priority 2) |
| Error recovery strategies 2+3 | 3/4 | Medium | Priority 4 emitted parser T2 |
| Incremental reuse guards | 5 | Medium | Add fragile/has_changes checks |
| Language-specific dispatch | 7 | Medium | Per-target JSON config (std.json, no deps) |
| CoarseTransitionSpec raw IDs | 7 | Low | Symbolic lookup at build time |
| MAX_VERSION_COUNT_OVERFLOW | 3 | Low | Add constant, not yet needed |
