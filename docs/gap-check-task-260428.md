# Task: Gap Analysis — gen-z-sitter vs tree-sitter (rev 2, 2026-04-28)

Supersedes `docs/gap-check-task.md` (2026-04-25 rev).
That document covered generator output parity (grammar → parser.c).
Those items are now closed. This revision covers the dimensions that have
opened since: parse-table algorithm convergence, behavioral harness fidelity,
the emitted GLR loop, incremental parsing, compat coverage breadth, and
structural code quality.

---

## Context

`~/prog/gen-z-sitter` is a Zig reimplementation of the tree-sitter **parser
generator** (grammar.json → parser.c). It has grown beyond a pure generator:

- `src/behavioral/harness.zig` — GLR simulation of the generated parser's runtime
  behavior. Used for correctness testing without compiling C.
- `src/parser_emit/parser_c.zig` — emits a `ts_generated_parse` GLR entry point
  alongside the standard `TSLanguage` struct (behind `GEN_Z_SITTER_ENABLE_GLR_LOOP`).
- `src/parse_table/` — LALR(1) builder with multi-action table, expected-conflict
  policy, optional state minimization, and coarse/thresholded-LR0 pressure modes.

The Rust reference is still `~/prog/tree-sitter`, but different files matter now:
- `crates/generate/src/render.rs` — generator output (mostly closed)
- `crates/generate/src/build_tables/` — parse-table algorithm
- `lib/src/parser.c` — the C runtime the generated parser links against
- `lib/src/parser.h` — TSLanguage ABI

Approach each area independently. Do not assume prior knowledge of what is done.

---

## Area 1 — Generator Output: Quick Verify

The original audit items are expected closed. Verify they are still correct
and look for any new divergences introduced by recent work.

```bash
# All add_ functions in the Rust generator:
grep -n "^    fn add_" ~/prog/tree-sitter/crates/generate/src/render.rs

# What the Zig emitter produces (top-level write calls):
grep -n "try write\|try emit\|fn write\|fn emit" \
  ~/prog/gen-z-sitter/src/parser_emit/parser_c.zig | head -60

# Optimization pragma — was a gap; check if now emitted:
grep -n "pragma\|GCC optimize\|clang optimize" \
  ~/prog/gen-z-sitter/src/parser_emit/compat.zig | head -10

# TSUnresolved side tables — gen-z-sitter extension not in upstream:
grep -n "TSUnresolved\|unresolved" \
  ~/prog/gen-z-sitter/src/parser_emit/parser_c.zig | head -10
```

Check for each `add_*` function in `render.rs`: does `parser_c.zig` produce an
equivalent? Pay special attention to `add_non_terminal_alias_map` (was a known stub),
`add_primary_state_id_list`, and `add_supertype_map`.

Note: `TSUnresolved` side tables are a gen-z-sitter extension with no upstream
equivalent. Record whether they compile cleanly against the tree-sitter C runtime ABI.

---

## Area 2 — Parse-Table Algorithm Convergence

Compare how gen-z-sitter builds action tables against the Rust reference.

```bash
# Upstream: how closure and actions are built
grep -n "fn add_actions\|fn add_reductions\|fn handle_conflict\|fn add_lookaheads" \
  ~/prog/tree-sitter/crates/generate/src/build_tables/build_parse_table.rs | head -20

# Upstream: expected_conflicts and GLR deferral
grep -n "expected_conflicts\|ambiguity\|glr\|defer" \
  ~/prog/tree-sitter/crates/generate/src/build_tables/build_parse_table.rs | head -20

# Zig: conflict resolution policy
grep -n "ExpectedConflictPolicy\|strict_expected\|unresolved\|candidate" \
  ~/prog/gen-z-sitter/src/parse_table/resolution.zig | head -30

# Zig: does it produce same state counts as upstream for shared grammars?
# Use tree_sitter_c_json: compare serialized_states in:
cat ~/prog/gen-z-sitter/compat_targets/parser_boundary_probe.json \
  | grep -A5 '"tree_sitter_c_json"'
```

Specific questions:
- When both generators process the same grammar.json, do they produce the same
  number of parse states? Same action table entries (modulo unresolved side tables)?
- Does gen-z-sitter's `expected_conflicts` matching cover the same cases as
  tree-sitter's `conflicts` field handling? (Check: tree-sitter serializes ambiguous
  entries silently; gen-z-sitter emits `TSUnresolved` — is the behavior identical
  for grammars that compile against the upstream C runtime?)
- Does gen-z-sitter's `thresholded_lr0` pressure mode produce tables that the
  upstream C runtime accepts correctly (no spurious rejects on valid input)?

---

## Area 3 — Behavioral Harness Fidelity

`src/behavioral/harness.zig` simulates the tree-sitter C runtime in Zig.
Compare the GLR loop shape, error recovery, and version management against
`lib/src/parser.c`.

```bash
# Upstream version management:
grep -n "MAX_VERSION\|condense_stack\|ts_parser__condense\|version_count\|error_cost" \
  ~/prog/tree-sitter/lib/src/parser.c | head -30

# Upstream error recovery stages:
grep -n "recover\|ERROR\|skip\|RECOVER\|error_cost\|is_error" \
  ~/prog/tree-sitter/lib/src/parser.c | grep -i "recover\|error" | head -20

# Zig harness version limit and condensation:
grep -n "MAX_PARSE_VERSIONS\|condenseVersions\|dynamic_precedence\|error_count" \
  ~/prog/gen-z-sitter/src/behavioral/harness.zig | head -20

# Zig harness error recovery:
grep -n "recoverFrom\|error_count\|error_cost\|stage.1\|stage.2" \
  ~/prog/gen-z-sitter/src/behavioral/harness.zig | head -20
```

Specific questions:
- **Version cap**: tree-sitter uses `TS_MAX_VERSION_COUNT = 6`. What does the
  harness use? Are they the same?
- **Condensation condition**: tree-sitter compares the full stack summary
  (`ts_parser__condense_stack` compares by `TSStackSummary`). The harness
  compares `cursor + stack_top`. Are there cases where the harness merges
  versions that tree-sitter would keep distinct, or vice versa?
- **Error recovery**: tree-sitter has three strategies (recover via summary,
  skip token, advance past error). Does the harness implement all three, or
  only two?
- **Dynamic precedence pruning**: tree-sitter prunes versions whose error cost
  exceeds the minimum by more than a threshold. Does the harness prune on the
  same condition?

---

## Area 4 — Emitted GLR Loop

`src/parser_emit/parser_c.zig` emits a `ts_generated_parse` function behind
`GEN_Z_SITTER_ENABLE_GLR_LOOP`. Compare this against the core parse loop in
`lib/src/parser.c`.

```bash
# The emitted GLR functions (all writeGlr* functions):
grep -n "^fn writeGlr\|^fn writeGlrMain\|^fn writeGlrDrive\|^fn writeGlrVersion\
\|^fn writeGlrInput\|^fn writeGlrAction" \
  ~/prog/gen-z-sitter/src/parser_emit/parser_c.zig

# Read the main parse function emitter:
sed -n '/fn writeGlrMainParseFunction/,/^fn [a-z]/p' \
  ~/prog/gen-z-sitter/src/parser_emit/parser_c.zig | head -80

# Upstream outer parse loop:
grep -n "ts_parser_advance\|ts_parser_do_all_potential_reductions\|outer.*loop\|while.*version" \
  ~/prog/tree-sitter/lib/src/parser.c | head -20

# Upstream reduce:
grep -n "ts_parser__do_all_potential_reductions\|ts_parser_reduce\|pop.*state\|goto_state" \
  ~/prog/tree-sitter/lib/src/parser.c | head -20
```

Specific questions:
- **Reduce completeness**: does `ts_generated_apply_parse_action` pop
  `child_count` states, look up the goto table, and push the new state — or
  does it only record the reduce info and leave the stack unchanged?
- **Reduce chain loop**: after a reduce, the same lookahead may trigger another
  reduce before the next shift. Does the emitted driver loop on reduce before
  advancing the lexer?
- **Divergent byte offsets**: when two versions have shifted different amounts
  (one shifted, one reduced), do their `byte_offset` fields diverge correctly?
  Does the outer loop lex per-offset-group rather than once globally?
- **Lexer integration**: how does the emitted GLR loop call `ts_lex`? Does it
  use `ts_lex_modes[state].lex_state` correctly per active version?

---

## Area 5 — Incremental Parsing Parity

`src/behavioral/harness.zig` exports `simulateIncremental`. Compare its reuse
logic against `ts_parser__reuse_node` in `lib/src/parser.c`.

```bash
# Upstream reuse conditions:
sed -n '/^static Subtree ts_parser__reuse_node/,/^}/p' \
  ~/prog/tree-sitter/lib/src/parser.c | head -60

# Zig reuse logic:
grep -n "simulateIncremental\|reuse\|entry_state\|start_byte\|old_tree\|Edit\b" \
  ~/prog/gen-z-sitter/src/behavioral/harness.zig | head -30

# External scanner guard:
grep -n "external_lex_state\|external.*guard\|scanner.*reuse\|reuse.*scanner" \
  ~/prog/gen-z-sitter/src/behavioral/harness.zig | head -10
```

Specific questions:
- **Reuse conditions**: tree-sitter checks `byte_range`, `parse_state`, and
  whether the node's `first_leaf_symbol` matches the current lookahead. Does
  `simulateIncremental` check all three, or only `entry_state + start_byte`?
- **Included-range differences**: tree-sitter guards reuse against
  `ts_parser__has_included_range_difference`. gen-z-sitter has no included
  ranges concept. Is this a correctness gap for any supported grammar?
- **Scanner-using grammars**: is incremental reuse limited to scanner-free
  grammars, or does it extend to grammars with external scanners?
- **Ambiguous grammars**: the yield-equivalence check for ambiguous grammars —
  is it complete, or still marked as a remaining item?

---

## Area 6 — Compat Coverage Gaps

Audit which grammars are at which proof level and why deferred ones are blocked.

```bash
# Current shortlist status:
cat ~/prog/gen-z-sitter/compat_targets/shortlist_report.json \
  | grep -E '"name"|"proof_scope"|"final_classification"|"blocked"' | head -60

# Parser boundary probe — why are deferred targets blocked?
cat ~/prog/gen-z-sitter/compat_targets/parser_boundary_probe.json \
  | grep -E '"display_name"|"final_classification"|"serialized_blocked"|"detail"' \
  | head -40

# State counts for deferred grammars:
grep -E "javascript|python|typescript|rust" \
  ~/prog/gen-z-sitter/compat_targets/parser_boundary_probe.json | head -20
```

Specific questions:
- At what stage are JavaScript, Python, TypeScript, and Rust blocked?
  (`prepare_only`, `serialize_only`, `emit_parser_c`, or `full_pipeline`?)
- Are they blocked by unresolved conflicts (serialization strict mode), by
  construction cost (timeout/OOM), or by an emitter gap?
- For grammars that DO pass at `full_runtime_link` (C JSON, Bash, Haskell, Zig,
  JSON): does the generated parser produce the same parse results as
  tree-sitter's reference generator for the sample inputs? Or only "no ERROR"?
- How many of tree-sitter's publicly listed grammars (~70) would the current
  generator attempt to handle vs. definitively block?

---

## Area 7 — Structural / Code Quality Gaps

```bash
# Language-specific functions in the harness:
grep -n "haskell\|Haskell\|bash_\|javascript_\|python_" \
  ~/prog/gen-z-sitter/src/compat/harness.zig | grep -v "test\|//\s" | head -20

# Per-target config files (if any):
find ~/prog/gen-z-sitter/compat_targets -name "build_config.*" 2>/dev/null

# CoarseTransitionSpec — hardcoded state/symbol IDs:
grep -n "source_state_id\|CoarseTransitionSpec" \
  ~/prog/gen-z-sitter/src/compat/harness.zig | head -20

# External dependencies:
cat ~/prog/gen-z-sitter/build.zig.zon
```

Specific questions:
- How many Haskell-specific named functions exist in `harness.zig`? Do any
  other targets have similar per-language guards?
- Is there a generic per-target config mechanism (`build_config.json` or
  `build_config.ziggy` in each `compat_targets/` subdirectory), or are all
  tuning parameters hardcoded?
- Are `CoarseTransitionSpec` entries expressed by grammar-meaningful names or
  by raw state/symbol IDs that will silently break if the grammar changes?
- Does `build.zig.zon` have any external dependencies? If not, and a Ziggy
  parser or other library is needed, what is the plan to add it?

---

## How to Examine the Code

Run these in sequence. Each takes under 30 seconds.

```bash
# 1. Generator output: list all add_ vs write* mappings
diff <(grep -o "fn add_[a-z_]*" ~/prog/tree-sitter/crates/generate/src/render.rs | sort -u) \
     <(grep -o "fn write[A-Z][a-zA-Z]*" ~/prog/gen-z-sitter/src/parser_emit/parser_c.zig | sort -u)

# 2. GLR loop completeness
grep -c "writeGlr" ~/prog/gen-z-sitter/src/parser_emit/parser_c.zig

# 3. Compat summary
cat ~/prog/gen-z-sitter/compat_targets/shortlist_report.json | grep -c '"passed"'
cat ~/prog/gen-z-sitter/compat_targets/shortlist_report.json | grep -c '"deferred"'

# 4. Haskell-specific function count
grep -c "fn shouldEnableHaskell\|fn haskellThresholded\|const haskell_" \
  ~/prog/gen-z-sitter/src/compat/harness.zig

# 5. Behavioral harness size vs. tree-sitter parser.c size (proxy for scope)
wc -l ~/prog/gen-z-sitter/src/behavioral/harness.zig \
       ~/prog/tree-sitter/lib/src/parser.c
```

---

## Output Format

Write a report with these sections:

### 1. Generator Output Parity
One line per `add_*` function: ✓ closed / ✗ gap / ~ extension.
Note any gen-z-sitter extensions (`TSUnresolved`) and whether they are ABI-safe.

### 2. Algorithm Convergence
For each question in Area 2: answer + evidence (file:line).
Note any grammars where state counts diverge from tree-sitter's output.

### 3. Behavioral Harness Gaps
Table: feature | tree-sitter behavior | harness behavior | gap?

### 4. Emitted GLR Loop Gaps
For each question in Area 4: implemented / missing / partial.
If partial: what specifically is missing.

### 5. Incremental Parsing Gaps
For each reuse condition: matches tree-sitter / diverges / not applicable.

### 6. Compat Coverage Summary
Table: grammar | proof_scope | blocked_at | reason.
Estimate what fraction of the public tree-sitter grammar ecosystem is reachable.

### 7. Structural Gaps
Count of language-specific functions. Severity: blocking / technical debt / cosmetic.

---

## Scope

Include:
- Generator correctness (grammar.json → parser.c)
- Parse-table algorithm faithfulness to tree-sitter
- Behavioral harness correctness vs. tree-sitter C runtime
- Emitted GLR loop correctness
- Incremental parsing correctness
- Compat coverage breadth
- Structural code quality

Exclude:
- tree-sitter C runtime internals beyond what the generated parser links against
- Grammar.js evaluation (implemented via Node.js subprocess; out of audit scope)
- Performance (covered separately by profiling infrastructure)
- Public TSTree/TSNode ABI compatibility (not yet a project goal)
