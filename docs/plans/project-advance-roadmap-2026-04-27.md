# Project Advance Roadmap — 2026-04-27

This plan is the broader project roadmap after the RW series and
`next-steps-270427_2.md`. It is intentionally larger than the next-step files:
those files can keep tracking small slices, while this document defines the
order in which the project should become a real, self-contained Zig generator
with credible tree-sitter compatibility.

## Current Position

The project now has:

- A Zig-only grammar loading, preparation, lexer, parse-table, serialization,
  and `parser.c` emission pipeline.
- Runtime table serialization for symbols, fields, aliases, supertypes,
  reserved words, lex modes, parse actions, large/small parse tables, and
  unresolved-action side tables.
- Bounded compatibility infrastructure with staged grammars and real grammar
  snapshots.
- Real external-scanner runtime-link proofs for staged scanners, Bash, and
  Haskell.
- Scanner-free behavioral GLR simulation with value stacks, tree building,
  error recovery, and an incremental parsing proof of concept.
- An opt-in emitted GLR loop in generated C with stack-pop/goto reduce handling,
  reduce-chain driving, raw-input lexing, divergent offset grouping, shifted
  tracking, and error-count pruning.

The largest remaining gap is not table emission anymore. The main gap is
runtime parity: scanner callback integration, emitted error recovery, runtime
tree construction, and promotion of larger real grammars without hiding heavy
or unbounded work in the default test suite.

## Non-Negotiable Constraints

- The implementation stays Zig-only and self-contained. Do not import
  tree-sitter source files into this project.
- Upstream tree-sitter is a reference implementation and test oracle only.
  Reproduce algorithms in Zig or in generated code owned by this project.
- Broad compatibility runs must stay bounded. Heavy runs belong behind explicit
  targets, timeouts, and progress reporting.
- Do not promote a real grammar to a wider routine boundary until the previous
  boundary has a measured, non-blocked proof.
- Keep generated C compatibility with the tree-sitter runtime ABI where needed,
  but avoid making the internal Zig pipeline depend on C implementation files.

## Phase 1 — Finish Emitted GLR Correctness

Goal: make the opt-in generated GLR parser handle the same parser-action
surfaces that the behavioral scanner-free GLR harness already handles.

### 1.1 No-Action Recovery

Implement the remaining Priority 4 item from `next-steps-270427_2.md`.

- [x] Add no-action recovery to generated `ts_generated_drive_version`.
- [x] Stage 1: scan backward through `version->stack` for a state that has a
  valid action for the current lookahead.
- [x] If found, shrink the stack, update `version->state`, increment
  `error_count`, and retry.
- [x] Stage 2: if no recovery state exists, advance the generated parse
  version by one input byte and return a recovery step for the outer loop.
- [x] Bound recovery attempts per outer iteration so malformed input cannot
  loop forever.
- [x] Add focused emitted-code tests for stack-backtracking snippets,
  `error_count` increments, and retry limits.

Gate:

- `timeout 30 zig build test --summary all`
- `timeout 30 zig build test-cli-generate --summary all`
- `timeout 30 zig build test-pipeline --summary all`
- `timeout 30 zig build test-pt --summary all`

### 1.2 Emitted GLR Runtime-Link Proofs

The emitted GLR loop currently has strong string-level emitter tests, but it
needs runtime proof on generated C.

- [x] Add a tiny scanner-free generated parser fixture with `glr_loop = true`.
- [x] Add a generated parser runtime-link test that calls `ts_generated_parse`
  directly on accepted input.
- [x] Add a fixture with one unresolved shift/reduce conflict and prove both:
  unresolved side tables are emitted, and the generated GLR loop accepts the
  intended input.
- [x] Add a malformed-input direct `ts_generated_parse` proof once no-action
  recovery lands.

Gate:

- Runtime-link tests finish under the bounded runtime-link target.
- Default generated parser output remains unchanged when `glr_loop = false`.

### 1.3 Runtime Tree Output

`ts_generated_parse` currently proves acceptance and consumed bytes. Real parser
parity needs tree construction or an explicitly scoped public result model.

- [x] Define the generated parser result model:
  - temporary internal tree for project tests, or
  - tree-sitter-compatible `TSTree`/`TSNode` ABI.
- [x] Add generated value stack entries for shifted terminals and reduced
  productions.
- [x] Build reduced parent nodes with byte ranges and production IDs.
- [x] Preserve alias and field metadata through the emitted tree path.
- [x] Add a staged test comparing generated tree strings with the runtime parser
  for a small grammar.

Gate:

- A scanner-free grammar can be parsed through generated C and produce a
  verifiable tree shape.

## Phase 2 — External Scanner Runtime in Generated GLR

Goal: unblock real grammar promotion. The current parser-boundary probe shows
JavaScript, Python, TypeScript, and Rust coarse serialization is blocked by
external scanner symbols, not unresolved parse-action signatures.

### 2.1 Generated Scanner Callback State

- [x] Extend generated GLR versions with external scanner payload state where
  the grammar has external tokens.
- [x] Store scanner serialized bytes per parse version, matching tree-sitter's
  clone/restore semantics.
- [x] Call `external_scanner_create`, `destroy`, `serialize`, `deserialize`,
  and `scan` from generated code where lex modes require external scanning.
- [x] Preserve per-version scanner state across forks.
- [x] Reuse the Bash and Haskell scanner include-dir/link patterns for generated
  GLR runtime-link tests.

Gate:

- Bash and Haskell runtime-link proofs pass through the generated GLR path, not
  only through regular `TSParser`.

### 2.2 External Scanner Valid-Symbol Tables

- [x] Verify `ts_external_scanner_states` and external symbol ordering match the
  generated scanner callback contract.
- [x] Add tests where two external tokens are valid in different states.
- [x] Add a stateful scanner test where serialize/deserialize is required after
  a GLR fork.

Gate:

- A forked parse version can choose a different external-scanner result without
  corrupting another version's scanner state.

### 2.3 Deferred Real Grammar Classification

Use the enhanced `parser_boundary_probe.json` to classify the real snapshots.

- [x] JavaScript: classify scanner tokens and decide whether a minimal scanner
  runtime proof can be built before full promotion.
- [x] Python: classify indentation scanner states and test a shallow sample plus
  one layout-sensitive sample.
- [x] TypeScript: classify scanner tokens and run a bounded coarse proof.
- [x] Rust: classify scanner tokens and run a bounded coarse proof.
- [x] Write target-specific notes in the plan or compatibility artifact before
  changing `parser_boundary_check_mode`.

Gate:

- No target moves from `prepare_only` to `serialize_only` unless the probe is
  non-blocked or the block is explicitly represented as a supported scanner
  boundary.

## Phase 3 — Real Grammar Promotion Ladder

Goal: increase real grammar coverage in small, measurable steps.

Promotion order:

1. Keep JSON as the baseline full-pipeline grammar.
2. Promote one scanner-free or scanner-light grammar at a time.
3. Promote Bash/Haskell generated GLR scanner proofs before JavaScript/Python.
4. Promote TypeScript/Rust only after their probe surfaces are classified and
   bounded.
5. JavaScript remains heavy until construction, emission, and C compile costs
   are measured with enough headroom.

For each candidate:

- [ ] Load/prepare proof.
- [ ] Coarse serialize proof.
- [ ] Lookahead-sensitive serialize proof.
- [ ] `parser.c` emission proof.
- [ ] Compile-smoke proof.
- [ ] Runtime-link proof on one accepted sample.
- [ ] Runtime-link proof on one invalid or partial sample after error recovery.
- [ ] Artifact refresh.

Implementation batches, in order:

1. JSON baseline runtime-link proofs.
   - [x] `tree_sitter_json_json` remains the scanner-free real JSON baseline
     with load, prepare, full parser emission, compatibility validation,
     compile-smoke, and bounded runtime-link proofs.
   - [x] Add accepted runtime-link proof for the real JSON snapshot on the
     empty document accepted by its `document := repeat(_value)` grammar.
   - [x] Add invalid runtime-link proof for the real JSON snapshot on `x`,
     asserting that the linked parser reports an error tree.

2. JSON tokenization and follow-set follow-up.
   - [x] Fix duplicate anonymous literal token identities so quoted string
     content does not force recovery after the opening quote.
   - [x] Add a focused accepted runtime-link proof for a non-empty real JSON
     string sample.
   - [x] Align the local parse-table item-set builder with upstream
     tree-sitter's transitive-closure addition model:
     `lookaheads`, `reserved_lookaheads`, and `propagates_lookaheads`.
   - [x] Replace the current split `direct_suffix_follow` /
     `nullable_ancestor_suffix_follow` propagation where it loses enclosing
     FOLLOW tokens before value separators.
   - [x] Add a focused parse-table test where a nested value reduces before
     `,`, `]`, and `}` in JSON-like object/array productions.
   - [x] Fix the remaining JSON number-ending proof only after the follow-set
     propagation test is green; numeric samples currently expose the same
     missing reduce lookahead surface as object/array samples.
   - [x] Broaden JSON accepted runtime-link samples to include at least one
     number, array, and object after the follow-set gap is fixed.
   - [x] Keep the invalid JSON runtime-link proof passing after the follow-set
     and lexer fixes.

3. Scanner-free/light real grammar promotion.
   - [x] Promote `tree_sitter_ziggy_json` runtime-link proof on one accepted
     sample if the current full-pipeline compile-smoke surface is enough.
   - [x] Promote `tree_sitter_ziggy_schema_json` runtime-link proof on one
     accepted sample if the current full-pipeline compile-smoke surface is
     enough.
   - [x] Add an invalid or partial sample for whichever Ziggy-family target is
     promoted first, or document why emitted recovery is not yet sufficient.

4. `tree_sitter_zig_json` promotion beyond coarse serialize.
   - [x] Move from routine coarse serialize-only evidence toward parser.c
     emission and compile-smoke if the bounded cost stays acceptable.
   - [x] Profile the direct runtime-link path with a scoped diagnostic that
     reports parser.c emission, driver generation, C compile/link, and linked
     driver runtime separately.
   - [x] Identify whether the 30s timeout comes from parser generation, C
     compile/link, generated parser execution, or recovery behavior.
   - [x] Re-run the runtime-link profiler in the same coarse closure mode used
     by the compat target.
   - [x] Diagnose the parser-context gap exposed by `const answer = 42;`: the
     compat-matching coarse closure mode shifts into a state with no terminal
     actions and an empty lex state, while upstream derives lex states from real
     terminal entries produced by lookahead-sensitive closure.
   - [x] Fix the parser-context gap exposed by `const answer = 42;`: the linked
     parser currently shifts `const` and the identifier, then reaches EOF/error
     instead of accepting `=`, the integer expression, and `;`.
   - [x] Add one accepted runtime-link sample only after the scoped diagnostic
     has clear headroom under the bounded test limit.
   - [x] Add one invalid or partial runtime-link sample after the accepted
     sample is stable and bounded.
   - Note: the scoped `tree_sitter_zig_json` compat target currently proves
     load, prepare, routine coarse serialization, parser table emission,
     parser.c emission, compatibility validation, and compile-smoke in about
     7.1s. Full lookahead runtime serialization still exceeds 60s before
     parser.c emission, but the compat-matching coarse closure mode completes
     runtime serialization in about 2.3s, parser.c emission in about 0.22s,
     C compile/link in about 4.6s, and linked driver execution in about 13ms.
     Accepted runtime-link promotion remains deferred because the current
     generated parser errors after the variable identifier in
     `const answer = 42;`. The focused diagnostic now identifies the immediate
     cause: `.closure_lookahead_mode = .none` produced completed closure items
     without reduce lookaheads. Coarse closure mode now adds SLR-style FOLLOW
     lookaheads to completed items, which lets the linked parser reduce the
     declaration header before `=` and `;`. The accepted Zig runtime-link sample
     is in the default bounded runtime-link suite; the invalid sample is kept as
     a focused bounded filter so the default suite retains headroom.

5. Scanner-wave evidence accounting.
   - [x] Ensure Bash and Haskell generated GLR scanner runtime-link proofs are
     reflected in Phase 3 artifacts as promoted scanner-wave evidence.
   - [x] Keep Bash/Haskell regular runtime-link proofs and generated GLR
     runtime-link proofs in the bounded suite.
   - [x] Refresh affected compatibility artifacts after this accounting change.

6. TypeScript/Rust bounded promotion probes.
   - [x] Try Rust first with a bounded parser-boundary or compile-smoke probe,
     using the Phase 2.3 scanner classification to avoid broad promotion while
     scanner symbols remain blocked.
   - [x] Try TypeScript only after Rust, and keep it in the heavy/bounded path
     unless timing has clear headroom.
   - [x] Keep JavaScript classified and deferred until construction, emission,
     and C compile costs have enough headroom.

7. Phase 3 closure.
   - [x] Refresh `shortlist_report.json`, `shortlist_inventory.json`,
     `parser_boundary_probe.json`, and any affected compatibility artifacts.
   - [x] Mark the per-candidate checklist above only for surfaces that are
     actually proven by the final Phase 3 batches.
   - [x] Record remaining deferred targets and blockers before moving to Phase
     4.

Gate:

- `shortlist_report.json`, `parser_boundary_probe.json`, and
  `shortlist_inventory.json` are refreshed after each promotion batch.
- Bounded suite remains acceptable by project decision, currently around the
  accepted `test-compat-heavy` cost.

## Phase 4 — Incremental Parsing Beyond the PoC

Goal: turn scanner-free incremental proof into an implementation that can be
trusted for scanner-using grammars.

### 4.0 Behavioral Harness Baseline

- [x] Resolve or reclassify the existing Haskell external-boundary fixture
  failure in `zig test src/behavioral_test_entry.zig`.
- [x] Decide whether full behavioral entry is expected to be green before
  scanner-aware incremental work continues.
- [x] Keep focused incremental filters as the Phase 4 gate until the Haskell
  baseline is fixed.

### 4.1 Scanner-Aware Incremental Harness

#### 4.1a Audit and Invariants

- [x] Document current scanner-free incremental assumptions in code comments
  near the reuse gate.
- [x] Add a regression test showing scanner-free append reuse still reuses
  prefix nodes.
- [x] Add a regression test showing external scanner state metadata blocks
  subtree reuse for otherwise reusable nodes.

#### 4.1b Scanner-Aware Reuse Gate

- [x] Add `simulatePreparedIncrementalWithExternalLexStates` as the first
  scanner-aware incremental entry point.
- [x] Do not reuse a subtree when its entry state has non-zero
  `external_lex_state`.
- [x] Keep scanner-free incremental tests passing.

#### 4.1c Scanner State Threading

- [x] Thread sampled serialized scanner-state snapshots through parse nodes and
  restore the state after a reused subtree.
- [x] Add a stateful scanner-state reuse regression proving
  restore-after-reuse behavior.

#### 4.1d Bracket-Lang Incremental Proof

- [x] Add `bracket_lang` incremental fixture.
- [x] Prove scanner-aware incremental parsing does not reuse unsafe subtrees.

Gate:

- Scanner-free incremental tests still pass.
- A scanner-using staged grammar reuses only safe subtrees.

### 4.2 Edit Model and Reuse Quality

- [x] Support insert, delete, and replace edits, not only append-like edits.
- [x] Track changed byte ranges and invalidate overlapping subtrees.
- [x] Add counters for reused nodes, reused bytes, and fresh-shifted tokens.
- [x] Add tests for edit-at-start, edit-in-middle, and edit-at-end.

Gate:

- Fresh and incremental parses have identical terminal yield for ambiguous
  grammars and identical tree shape for unambiguous grammars.

## Phase 5 — Performance and Memory

Goal: keep large grammar work practical without hiding regressions.

### 5.1 Construction Profiling

- [x] Keep construct-stage profiling available through env flags.
- [x] Re-profile C JSON, Zig, TypeScript, Rust, and JavaScript after each major
  parse-table change.
- [x] Track construction time, serialization time, emission time, MaxRSS, and
  allocator churn.
- [x] Store representative measurements in a lightweight artifact or plan note:
  `docs/plans/phase5-profile-2026-04-27.md`.

### 5.2 Data Structure Improvements

Candidate optimizations, only after measurements justify them:

- [ ] SymbolSet bitset compression if allocation churn remains high.
- [ ] Closure cache key compaction if closure misses dominate.
- [ ] State interning improvements if `state_intern_calls` greatly exceeds
  `state_intern_reused`.
- [x] Parse-action list and small-table dedup audits for large grammars.
- [x] Replace linear multi-action-list dedup lookup with hashed action-slice
  lookup after JavaScript profiling showed parse-action-list growth as the
  strongest bounded signal.

Current Phase 5 profile note: SymbolSet allocation churn is visible but not the
dominant C JSON signal; JavaScript now reports an explicit
`ParseActionListTooLarge` boundary instead of overflowing in Debug. Hashing
multi-action-list dedup reduced the JavaScript bounded serialize failure from
about 21.7s to about 19.2s, but not enough to remove the boundary.

### 5.3 Parse Action List Capacity

- [x] Replace linear multi-action-list dedup with hashed action-slice lookup.
- [x] Measure parse-action-list entry count and flattened width per large
  grammar.
- [x] Add a profile summary for unique single actions, reusable multi-action
  rows, and unresolved rows.
- [ ] Investigate upstream-compatible packing before widening table values.
- [ ] Decide whether a wider-index experimental mode is acceptable for
  non-runtime-compatible generated parsers.

Current JavaScript capacity profile: `entries=23424`, `flat_width=65537`,
`capacity=65536`, `single_unique=4922`, `unresolved_unique=18501`, and
`unresolved_flat_width=55693`. The overflow is one flattened slot beyond the
runtime-compatible `uint16_t` table value range, with unresolved diagnostic rows
dominating the remaining capacity pressure.

Gate:

- No structural optimization lands without before/after numbers on at least one
  real grammar.

## Phase 6 — Generated C Compatibility Surface

Goal: make generated C robust enough for downstream parser consumers.

- [ ] Add missing compiler pragmas only where measured compile time requires
  them.
- [ ] Finish TSCharacterRange compatibility if large Unicode grammars need it.
- [ ] Audit generated ABI structs against the tree-sitter runtime headers.
- [ ] Add compile-smoke tests for C11, common warnings, and large lex tables.
- [ ] Decide when public `tree_sitter_<name>()` naming should replace the
  current generic entry point in generated output.

Gate:

- Generated parsers compile with `zig cc -std=c11` and link against the
  reference tree-sitter runtime for promoted targets.

## Phase 7 — Tooling and User Workflow

Goal: make the project useful as a command-line generator.

- [ ] Clarify the project executable name in README, help text, and examples.
- [ ] Add command examples for:
  - generating `parser.c`,
  - writing summary JSON,
  - using `--minimize`,
  - enabling GLR emitted loop experiments,
  - running bounded compatibility checks.
- [ ] Add a “known limits” section covering external scanners, generated tree
  output, and heavy grammars.
- [ ] Add a generated-output golden update workflow that is explicit and
  bounded.

Gate:

- A new user can run the generator on a small grammar and understand which
  compatibility level the output claims.

## Phase 8 — Release Readiness

The project is release-ready only when these are true:

- [ ] JSON and at least two additional real grammars pass full pipeline.
- [x] At least one real external-scanner grammar passes generated GLR
  runtime-link proof.
- [ ] Generated parser has either tree output or a clearly documented accepted
  temporary result API.
- [ ] Error recovery is implemented in the emitted parser or explicitly disabled
  with a visible compatibility warning.
- [ ] Heavy compatibility tests are bounded, documented, and separate from fast
  local tests.
- [ ] README documents the actual executable name, current compatibility level,
  and limitations.
- [ ] No tree-sitter implementation files are vendored into the project.

## Recommended Immediate Order

1. Finish emitted no-action recovery in generated GLR.
2. Add direct `ts_generated_parse` runtime-link tests.
3. Add external scanner callback support to generated GLR.
4. Prove Bash or Haskell through the generated GLR scanner path.
5. Reclassify JavaScript, Python, TypeScript, and Rust based on supported
   scanner boundaries.
6. Promote one real grammar at a time with artifacts refreshed after each batch.

This order keeps the next work tied to correctness gates and avoids spending
time on large grammar promotion before the generated runtime can actually model
the scanner and recovery surfaces those grammars require.
