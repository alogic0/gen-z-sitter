# Tree-sitter Gap Reduction Plan — 2026-04-28

This plan starts after the staged release-readiness work in
`project-advance-roadmap-2026-04-27.md`. The goal is to reduce the remaining
gap with upstream Tree-sitter significantly again, not by vendoring upstream
files, but by reproducing the important generator and runtime algorithms in
Zig with differential evidence.

## Constraints

- Keep the project Zig-only and self-contained.
- Do not copy Tree-sitter implementation files into this repository.
- Use `../tree-sitter` as a reference implementation, source of algorithms, and
  external runtime/test oracle only.
- Keep routine tests bounded. Heavy corpus and real-grammar work must remain
  explicit, timed, and resumable.
- Do not promote a grammar or algorithm surface based only on emission success.
  Require at least one runtime or differential proof at the appropriate layer.

## Upstream Reference Map

Use these upstream areas as algorithm references while implementing local Zig
equivalents:

- Grammar parsing and DSL loading:
  - `../tree-sitter/crates/generate/src/parse_grammar.rs`
  - `../tree-sitter/crates/generate/src/dsl.js`
  - `../tree-sitter/crates/generate/src/grammars.rs`
- Grammar preparation:
  - `../tree-sitter/crates/generate/src/prepare_grammar.rs`
  - `../tree-sitter/crates/generate/src/prepare_grammar/flatten_grammar.rs`
  - `../tree-sitter/crates/generate/src/prepare_grammar/intern_symbols.rs`
  - `../tree-sitter/crates/generate/src/prepare_grammar/extract_tokens.rs`
  - `../tree-sitter/crates/generate/src/prepare_grammar/expand_repeats.rs`
  - `../tree-sitter/crates/generate/src/prepare_grammar/expand_tokens.rs`
  - `../tree-sitter/crates/generate/src/prepare_grammar/process_inlines.rs`
  - `../tree-sitter/crates/generate/src/prepare_grammar/extract_default_aliases.rs`
- Table construction:
  - `../tree-sitter/crates/generate/src/build_tables.rs`
  - `../tree-sitter/crates/generate/src/build_tables/item.rs`
  - `../tree-sitter/crates/generate/src/build_tables/item_set_builder.rs`
  - `../tree-sitter/crates/generate/src/build_tables/build_parse_table.rs`
  - `../tree-sitter/crates/generate/src/build_tables/build_lex_table.rs`
  - `../tree-sitter/crates/generate/src/build_tables/token_conflicts.rs`
  - `../tree-sitter/crates/generate/src/build_tables/coincident_tokens.rs`
  - `../tree-sitter/crates/generate/src/build_tables/minimize_parse_table.rs`
- C output rendering:
  - `../tree-sitter/crates/generate/src/render.rs`
  - `../tree-sitter/crates/generate/src/parser.h.inc`
- Runtime behavior:
  - `../tree-sitter/lib/src/parser.c`
  - `../tree-sitter/lib/src/stack.c`
  - `../tree-sitter/lib/src/reusable_node.h`
  - `../tree-sitter/lib/src/lexer.c`
  - `../tree-sitter/lib/src/subtree.c`
  - `../tree-sitter/lib/src/tree.c`
  - `../tree-sitter/lib/src/get_changed_ranges.c`

## Target Outcome

The next major compatibility boundary should prove:

- JSON, Ziggy-family, Zig, C, Bash, and Haskell remain promoted and bounded.
- At least one of JavaScript, Python, Rust, or TypeScript advances by a real
  boundary, not just by a diagnostic note.
- Generated `parser.c` can be compared against upstream on corpus samples for
  selected grammars.
- Grammar-prep and parse-table differences are explainable from machine-readable
  artifacts.
- The project has a repeatable compatibility workflow that can answer "where do
  we differ from upstream?" without a one-off manual investigation.

## Phase 1 — Differential Oracle Infrastructure

Goal: make upstream comparison routine and cheap enough to drive every later
phase.

### 1.1 Upstream Snapshot Driver

- [x] Add a bounded tool or build step that runs upstream Tree-sitter generation
  for one selected compat target from `../tree-sitter`.
- [x] Capture upstream `parser.c`, `node-types.json`, generated symbol metadata,
  parse-state count, lex-state count, external token count, and parse-action
  table sizes into `.zig-cache/` artifacts.
- [x] Keep generated upstream artifacts out of source control.
- [x] Add clear skip behavior when `../tree-sitter` or `node` is missing.

Batch 1 note: `gen-z-sitter compare-upstream` and `zig build
run-compare-upstream` now write a local/upstream summary envelope under
`.zig-cache/upstream-compare` by default.

Batch 2 note: when a `tree-sitter` executable is available, the command now
runs upstream `tree-sitter generate`, stores upstream `parser.c` and
`node-types.json` under `.zig-cache/upstream-compare/upstream`, and parses the
generated C for the first stable summary fields. Missing checkout/tool cases
remain explicit skip statuses instead of hard failures.

Gate:

- A single promoted target can produce local and upstream summaries in one
  bounded command without committing upstream output.

### 1.2 Local-vs-Upstream Summary Diff

- [x] Add a compact JSON diff format for generator-level differences.
- [x] Compare grammar name, ABI metadata, symbol count/order, field names,
  alias rows, lex modes, external scanner states, parse-state count, large-state
  count, parse-action list width, and small-table size.
- [x] Classify each diff as:
  - [x] expected local extension,
  - [x] known unsupported surface,
  - [x] suspected algorithm gap,
  - [x] regression.
- [x] Add focused tests for the diff classifier using synthetic summaries.

Gate:

- Running the diff on JSON produces either no differences or explicitly
  classified differences.

### 1.3 Corpus Sample Harness

- [x] Add a bounded corpus sample runner that can parse a small list of input
  files with both upstream-generated parser/runtime and local-generated parser.
- [x] Compare accepted/error status, consumed bytes, and root tree string.
- [x] Store target sample lists in compat metadata, not as broad filesystem
  crawls.
- [x] Keep full corpus runs outside default tests.

Batch 2 note: the first corpus comparison is intentionally bounded through the
explicit `run-compare-upstream` command. For JSON, upstream parses `{}` and `x`
and records the expected tree/error strings. The local generated parser runner
currently times out on those samples, so the report records
`corpus_samples.status = "runner_failed"` instead of hanging. That is now a
machine-readable Phase 2/5 input, not hidden test-suite behavior. The same
bounded command was also run against Ziggy as the first non-JSON promoted
grammar probe; it records the same local-runner timeout boundary while upstream
produces `(document)` for the empty sample.

Gate:

- JSON and one non-trivial promoted grammar have accepted and invalid corpus
  samples compared against upstream.

## Phase 2 — Grammar Preparation Parity

Goal: remove hidden differences before table construction starts.

### 2.1 DSL and Raw Grammar Semantics

- [x] Audit local `grammar.js` loading against upstream `dsl.js`.
- [x] Cover `prec`, `prec.left`, `prec.right`, `prec.dynamic`, `token`,
  `token.immediate`, `alias`, `field`, `repeat`, `repeat1`, `optional`,
  `choice`, `seq`, `blank`, `reserved`, `conflicts`, `externals`,
  `inline`, `supertypes`, `word`, and `extras`.
- [ ] Add grammar-loader differential fixtures that serialize both upstream and
  local raw grammar structure.
  - [x] Write a normalized local `raw-grammar.json` artifact for comparison
    runs.
  - [ ] Add or discover an upstream raw-grammar oracle that is independent of
    generated `parser.c`.
- [x] Make unsupported DSL constructs fail explicitly with target name and rule
  path.

Batch 3 note: `docs/plans/dsl-coverage-2026-04-28.md` records the current DSL
coverage matrix. The important correction is that local `grammar.js` loading
does not inject upstream `dsl.js`; it expects a module that exports a
JSON-shaped grammar object. Upstream `tree-sitter generate --no-parser` did not
produce a normalized `grammar.json` for the JSON snapshot, so raw-grammar
differential fixtures need a different oracle than the standard upstream output
directory.

Batch 9 note: unknown JSON DSL rule types now fail as `UnsupportedRuleType`
with a note containing the grammar name, rule path, and unsupported raw type.
The generate command prints this note through the standard diagnostic path, so
new real-grammar gaps identify the exact unsupported construct instead of
collapsing into a generic invalid shape error.

Batch 14 note: local comparison artifacts now include `raw-grammar.json`, a
normalized serialization of the loaded raw grammar rules, externals, extras,
precedences, conflicts, reserved sets, supertypes, inline list, and word token.
The upstream side remains open because `tree-sitter generate` does not expose a
raw normalized grammar artifact.

Gate:

- A DSL coverage matrix says which constructs are supported, blocked, or
  intentionally deferred.

### 2.2 Preparation Pipeline Order

- [x] Verify local pass order against upstream preparation order.
  - [ ] Align local repeat/default-alias/flatten ordering with upstream or
    document the exact equivalent local invariants.
  - [x] Add local indirect-recursion validation matching upstream
    `validate_indirect_recursion`.
  - [x] Add explicit lexical token expansion/inlining artifacts or equivalent
    summaries for the local pipeline.
- [ ] Add a prepared-IR diff for variables, hidden rules, inlined rules,
  auxiliary rules, lexical variables, external tokens, conflicts, and
  precedence ordering.
  - [x] Add deterministic local prepared/extracted/flattened IR summary
    counts and hashes to the upstream comparison report.
  - [x] Write a detailed local `prepared-ir.json` artifact with prepared
    variables, symbols, extracted lexical variables, and flattened syntax
    variable counts.
- [ ] Reproduce upstream repeat expansion and dedup behavior where local names
  or rule shapes still differ.
- [ ] Reproduce upstream token extraction behavior for hidden terminals,
  duplicate literals, token aliases, and external/internal token pairing.
  - [x] Use literal names for nested string/pattern terminals while keeping
    top-level lexical rules named after their grammar variable.
  - [x] Keep nested composite token extraction from crashing when no literal
    terminal name exists.
  - [x] Extract public all-pattern composite lexical rules as named terminals
    while preserving syntax-side repeat auxiliaries and hidden extras.

Gate:

- JSON, Ziggy, Zig, C, Bash, and Haskell prepared summaries are diffable with
  no unclassified preparation gaps.

Batch 8 note: `compare-upstream` now emits a `local_prepared_ir` section with
prepared variable/symbol hashes plus extracted lexical and flattened syntax
counts/hashes. This is intentionally local-only until an upstream prepared-IR
oracle is added, but it gives future preparation changes a stable artifact and
keeps pass-order work separate from parse-table construction.

Batch 10 note: local comparison artifacts now include `prepared-ir.json` beside
`parser.c` and `node-types.json`. The snapshot records prepared variables and
symbols, extracted lexical variables including source kind, and flattened
syntax variable production/step counts, giving future upstream/local prep diffs
a stable machine-readable local side.

Batch 11 note: upstream preparation order was checked in
`../tree-sitter/crates/generate/src/prepare_grammar.rs`. Upstream runs
validate precedences, validate indirect recursion, intern symbols, extract
tokens, expand repeats, flatten syntax, expand lexical tokens, extract default
aliases, and process inlines. The local snapshot now records its stage order;
remaining mismatches are tracked explicitly instead of being hidden inside the
generic pass-order checkbox.

Batch 12 note: local raw-grammar lowering now rejects indirect recursion
through chains of single-symbol productions, matching upstream's
`validate_indirect_recursion` guard. The diagnostic records the recursive rule
chain so ambiguous real-grammar failures are visible before symbol lowering.

Batch 13 note: `prepared-ir.json` now records lexical separators, external
tokens, extra symbols, expected conflicts, precedence orderings,
variables-to-inline, supertypes, and the word token. These are local
equivalent artifacts for upstream lexical expansion/inlining surfaces until a
direct upstream prepared-IR dump exists.

### 2.3 Node Types, Fields, Aliases, and Supertypes

- [x] Compare local `node-types.json` with upstream for promoted targets.
- [ ] Fix field `multiple` and `required` classification mismatches.
  - [x] Match JSON `children` and field required/multiple quantities against
    upstream, including blank alternatives and self-recursive repeat helpers.
  - [x] Match Ziggy empty `fields: {}` emission and node-type ordering for
    named syntax leaves that lower through lexical/repeat-token paths.
  - [x] Apply field metadata to every lowered child of a wrapped sequence or
    choice, matching Ziggy Schema field `multiple` and type aggregation.
- [ ] Fix alias visibility/namedness mismatches.
  - [x] Materialize anonymous per-step aliases as top-level node-types entries,
    matching Ziggy Schema `_tag_name`.
- [ ] Fix supertype and subtype ordering mismatches.
  - [x] Treat hidden supertypes as visible named child/field entries in
    node-types computation.
- [ ] Add a golden-refresh command that only updates local goldens after the
  upstream comparison is clean or classified.

Gate:

- JSON and two real non-JSON targets have node-types output matching upstream or
  explicitly classified.

Batch 3 note: `compare-upstream` now writes local `node-types.json` under the
local comparison artifact directory and adds a normalized `node_types_hash` to
both local and upstream summaries. JSON currently reports a node-types hash
difference, which becomes the next focused Phase 2.3 diagnostic target.

Batch 4 note: `compare-upstream` now includes a `node_types_diff` section that
compares top-level node type identities by `{type, named}`. For JSON, the first
actionable difference is that upstream includes anonymous punctuation nodes
(`"`, `,`, `:`, `[`, `]`, `{`, `}`) that are absent from the local
`node-types.json`. Field quantity and child-shape diffs remain the next
node-types diagnostic layer.

Batch 5 note: JSON `node-types.json` now hashes exactly with upstream. The fix
covered nested literal token names, named lexical self-child removal, hidden
supertype child visibility, blank-alternative requiredness, self-recursive
repeat multiplicity, and empty `fields: {}` emission for non-leaf syntax nodes.
The Ziggy comparison still reports extra anonymous regex component node types,
so the next node-types target is distinguishing public token entries from
lexical helper terminals in composite token extraction.

Batch 6 note: Ziggy `node-types.json` now hashes exactly with upstream while
preserving the JSON hash match. The fix distinguishes string, pattern,
composite, and token lexical sources, keeps anonymous regex/token helpers out
of public node-types, and models upstream's empty `fields: {}` presence rule
for syntax leaves that still carry syntax shape.

Batch 7 note: Ziggy Schema `node-types.json` now hashes exactly with upstream.
The fix materializes anonymous step aliases and applies field metadata across
all children lowered from a field-wrapped sequence/choice. With JSON, Ziggy,
and Ziggy Schema matching upstream by node-types hash, the Phase 2.3 gate is
satisfied for one simple real target and two non-JSON promoted targets.

## Phase 3 — Parse Table Algorithm Parity

Goal: make parse-table differences explainable and shrink the remaining
lookahead, conflict, and minimization gaps.

### 3.1 Item-Set and Closure Differential Tests

- [ ] Add an item-set snapshot mode for selected states.
  - [x] Write local `parse-states.txt` item-set dumps into comparison
    artifacts.
  - [x] Add selected-state filtering for local comparison artifacts.
  - [x] Write compact local item-set summary hashes for cores, lookaheads,
    transitions, and conflicts.
  - [ ] Add upstream-shaped item-set comparison.
- [ ] Compare kernel items, closure additions, lookaheads, reserved lookaheads,
  and propagation flags against upstream concepts from `item_set_builder.rs`.
- [ ] Add fixtures for nullable suffixes, nested repeats, expected conflicts,
  dynamic precedence, and token.immediate interactions.
- [ ] Remove any remaining coarse-mode behavior from promoted runtime paths
  unless the target is explicitly classified as diagnostic-only.

Gate:

- The JSON follow-set fixes are protected by upstream-shaped item-set tests,
  not only runtime-link samples.

Batch 15 note: local comparison artifacts now include `parse-states.txt`, using
the existing deterministic item-set/state dump. This is the local side of the
Phase 3 item-set snapshot work; selected-state filtering and upstream-shaped
comparison remain open.

Batch 16 note: `compare-upstream` now accepts `--report-states-for-rule`, and
`zig build run-compare-upstream` exposes it as
`-Dupstream-compare-report-states-for-rule=<rule>`. When set, local
`parse-states.txt` is limited to states referencing that rule and includes the
same selected-state action context used by the generate debug path.

Batch 17 note: local comparison artifacts now include
`parse-states-summary.json`, a compact machine-readable item-set summary with
state, production, item, transition, and conflict counts plus stable hashes for
cores, lookaheads, transitions, and conflicts.

### 3.2 Conflict Resolution and Expected Conflicts

- [ ] Audit local conflict resolution against upstream
  `build_parse_table.rs` conflict handling.
- [x] Write local conflict summary artifacts with declared expected-conflict
  counts, unused expected-conflict indexes, and unresolved reason counts.
- [ ] Add differential fixtures for:
  - shift/reduce resolved by static precedence,
  - shift/reduce resolved by associativity,
  - reduce/reduce resolved by precedence,
  - dynamic precedence preserved as unresolved runtime choice,
  - [x] expected conflict allowed,
  - [x] unexpected conflict rejected.
- [ ] Ensure error messages identify the same useful parent rules that upstream
  reports.

Gate:

- The local generator rejects the same intentionally ambiguous fixture that
  upstream rejects and accepts the same expected-conflict variant.

Batch 18 note: local comparison artifacts now include
`conflict-summary.json`, recording declared expected conflicts, unused expected
conflict indexes, total unresolved decisions, and unresolved reason counts.
This gives conflict-resolution work a stable local baseline before adding
upstream-shaped conflict comparison fixtures.

Batch 19 note: compare-upstream now writes local artifacts before the upstream
runtime/corpus gate. Intentionally rejected conflict fixtures still produce
local `conflict-summary.json`; the expected shift/reduce fixture records
`shift_reduce_expected: 1`, while the unexpected fixture records
`shift_reduce: 1`.

### 3.3 Token Conflicts and Lexical Precedence

- [ ] Reproduce upstream token conflict analysis for overlapping literals,
  regex tokens, externals, keywords, and immediate tokens.
- [x] Add local summaries for coincident token groups and lexical conflict
  pairs.
- [ ] Use those summaries in parse-state minimization and lex-mode assignment.

Gate:

- State minimization never merges states that upstream would split because of
  token conflicts or external/internal token interaction.

Batch 20 note: local comparison artifacts now include `token-conflicts.json`,
with lexer variable counts, per-token starting/following ranges, grammar-based
following-token counts, and directional conflict-pair flags for same-string,
prefix, continuation, separator, different-string, and starting-overlap cases.

### 3.4 Minimize Parse Table Parity

- [ ] Audit local minimization against upstream `minimize_parse_table.rs`.
- [ ] Compare removed unit reductions, merged compatible states, unused-state
  removal, and descending-size reorder.
- [ ] Preserve correct primary state IDs, lex modes, external lex states, and
  production metadata after minimization.
- [x] Add a local minimization summary artifact for selected comparison
  grammars.
- [ ] Add a minimization diff report for large real grammars.

Gate:

- `--minimize` can be enabled for promoted compile-smoke targets without
  changing runtime-link results.

Batch 21 note: local comparison artifacts now include
`minimization-summary.json`, comparing default and minimized serialized table
counts for the selected grammar. It records state, large-state, small-row,
parse-action-list, action-entry, goto-entry, unresolved-entry, merged-state,
removed-action-entry, and removed-goto-entry counts.

## Phase 4 — Lexer and Regex Parity

Goal: close the scanner-free lexical gap enough for larger real grammars.

### 4.1 Regex Feature Coverage

- [ ] Audit local regex support against the regex constructs present in staged
  real grammars.
- [x] Add local regex-surface artifacts that list pattern tokens and classify
  regex features by token name.
- [ ] Add explicit support or explicit diagnostics for character classes,
  escapes, Unicode categories, ranges, repetitions, anchors as used by
  Tree-sitter grammar tokens, and immediate-token boundaries.
- [ ] Add grammar-level tests where regex support affects accepted input, not
  just regex unit tests.

Gate:

- C, Zig, Rust, JavaScript, Python, and TypeScript regex-token surfaces are
  classified as supported or blocked with exact token names.

Batch 22 note: local comparison artifacts now include `regex-surface.json`,
listing lexical variables that contain regex patterns and classifying each
pattern for flags, character classes, escapes, Unicode properties, bounded
repeats, groups, alternation, anchors, and dot usage. This gives real-grammar
regex blockers exact token names and pattern strings before changing lexer
behavior.

### 4.2 Lex Table Construction

- [ ] Audit local NFA/DFA construction against upstream `nfa.rs` and
  `build_lex_table.rs`.
- [ ] Compare lex-state counts, accept token priorities, advance actions,
  skip actions, and large character set decisions.
- [ ] Reproduce upstream keyword lexer behavior for real word-token grammars.
- [ ] Protect external-token valid-symbol behavior with stateful scanner tests.

Gate:

- Local and upstream lex summaries match or are classified for JSON, C, Zig,
  Bash, and Haskell.

### 4.3 Emitted Lexer C Parity

- [ ] Compare generated lex function structure at the summary level, not by
  exact text.
- [ ] Keep compiler-pragmas and large-character-set output measured.
- [ ] Add compile-time profiling for large lexers and keep regression limits in
  the heavy suite.

Gate:

- Large lexer targets compile under the accepted bounded heavy budget.

## Phase 5 — Runtime Parser Behavior Parity

Goal: make the generated parser behave like a real Tree-sitter parser for
selected grammars, not only compile and link.

### 5.1 Stack and Dynamic Precedence

- [ ] Audit generated GLR stack behavior against upstream `stack.c`.
- [ ] Add tests for stack version merge, split, dynamic precedence selection,
  subtree reuse decisions, paused versions, and last external token state.
- [ ] Preserve dynamic precedence through generated result trees.

Gate:

- A dynamic-precedence fixture chooses the same tree as upstream.

### 5.2 Error Recovery

- [ ] Audit emitted recovery against upstream `parser.c` recovery behavior.
- [ ] Add error-cost accounting, recovery token insertion/deletion surfaces,
  and bounded retry reporting.
- [ ] Compare invalid sample tree strings for promoted grammars where upstream
  produces a stable error tree.

Gate:

- JSON and one non-JSON target have invalid-input tree strings compared against
  upstream.

### 5.3 Incremental Parsing and Reuse

- [ ] Audit local incremental reuse against upstream `reusable_node.h`,
  `get_changed_ranges.c`, and stack scanner-state handling.
- [ ] Compare changed ranges, reused bytes, and final tree strings for edit
  samples.
- [ ] Add scanner-aware incremental samples for Bash or Haskell after external
  scanner state snapshots are stable.

Gate:

- One scanner-free target and one scanner target have bounded incremental
  equivalence samples.

### 5.4 Public Tree API Direction

- [ ] Decide whether to continue with the temporary generated result/tree-string
  API or introduce a Tree-sitter-compatible tree ABI subset.
- [ ] If a compatible subset is chosen, reproduce only the required structs and
  ownership behavior in generated/self-contained code.
- [ ] Keep the temporary API documented until the compatible API has runtime
  proofs.

Gate:

- Users can tell from generated output whether they are using temporary project
  APIs or a Tree-sitter-compatible subset.

## Phase 6 — Real Grammar Promotion Wave

Goal: advance large real grammars by measured boundaries.

### 6.1 Promotion Ladder

For each target, advance only one boundary at a time:

- [ ] load and prepare
- [ ] prepared-IR diff
- [ ] lex summary diff
- [ ] parse-table summary diff
- [ ] parser.c emission
- [ ] compile-smoke
- [ ] accepted runtime-link sample
- [ ] invalid runtime-link sample
- [ ] corpus sample comparison
- [ ] incremental sample comparison where relevant

### 6.2 Target Order

Use this order unless profiling shows a clear reason to change it:

- [ ] C: scanner-free baseline for broad syntax and larger tables.
- [ ] Bash: real external scanner proof with shell-specific samples.
- [ ] Haskell: layout-sensitive external scanner proof.
- [ ] Rust: scanner/regex-heavy target before JavaScript.
- [ ] Python: indentation-sensitive target after scanner state improves.
- [ ] JavaScript: large conflict/regex/keyword target.
- [ ] TypeScript: defer until JavaScript surfaces are stable.

### 6.3 Promotion Artifact Discipline

- [ ] Every promotion updates `compat_targets/shortlist_report.json`.
- [ ] Every deferred target records the exact blocker and next proof.
- [ ] Heavy timings are stored in `docs/plans` or compat artifacts.
- [ ] No target enters the default bounded suite without clear headroom.

Gate:

- At least one target from Rust, Python, JavaScript, or TypeScript moves to a
  stronger boundary than it has today.

## Phase 7 — Performance and Capacity

Goal: keep correctness work practical for large grammars.

### 7.1 Parse Construction Costs

- [ ] Keep per-stage construction profiling enabled for real grammar targets.
- [ ] Finish SymbolSet bitset compression if allocation churn remains visible.
- [ ] Compact closure and item-set keys if cache misses dominate.
- [ ] Add state-interning metrics to promotion artifacts.

Gate:

- Large real grammar profiling identifies the current bottleneck before any
  structural optimization lands.

### 7.2 Runtime Table Capacity

- [ ] Keep runtime-compatible `uint16_t` table limits for normal output.
- [ ] Move diagnostic-only unresolved action data out of runtime action-list
  capacity paths where possible.
- [ ] Add explicit errors for targets that exceed runtime-compatible limits.
- [ ] Defer wider experimental indexes until there is a user-visible consumer.

Gate:

- JavaScript-style diagnostic overflow is reported without corrupting
  runtime-shaped tables.

### 7.3 C Compile Time

- [ ] Track parser.c size, lex function size, compile time, and MaxRSS for large
  generated parsers.
- [ ] Add bounded compile-smoke profiling for C, Rust, JavaScript, and
  TypeScript.
- [ ] Tune emitted C shape only when measurements show compile time is the
  blocker.

Gate:

- Heavy compile-smoke failures say whether generation, C compile, or linked
  runtime execution exceeded the budget.

## Phase 8 — User-Facing Compatibility Contracts

Goal: make compatibility claims precise and useful.

- [ ] Add a `gen-z-sitter compat-report` or equivalent command that prints the
  current support boundary for a grammar.
- [ ] Expose whether a generated parser is scanner-free, scanner-linked,
  temporary-GLR, runtime-compatible, corpus-compared, or diagnostic-only.
- [ ] Add generated parser metadata strings for known compatibility limits.
- [ ] Document how users can reproduce the upstream comparison for their grammar.

Gate:

- A user can run one command and understand whether the generated output is
  suitable for inspection, compile-smoke, runtime-link proof, or experimental
  parsing.

## Suggested Implementation Order

1. Phase 1.1 and 1.2: upstream/local summary oracle.
2. Phase 2.1 and 2.2: grammar preparation diff, because later table diffs are
   noisy without it.
3. Phase 3.1 and 3.2: item-set and conflict parity.
4. Phase 4.1: regex/token support classification for real grammar blockers.
5. Phase 6.1 on C: first larger scanner-free promotion wave.
6. Phase 5.1 and 5.2: runtime stack and recovery parity where corpus samples
   expose real behavior differences.
7. Phase 6.1 on Bash/Haskell/Python: scanner-state promotion wave.
8. Phase 7 targeted optimizations only after profile artifacts point to a
   bottleneck.
9. Phase 8 compatibility-report UX after the evidence model is stable.

## Batch Policy

- Small mechanical fixes can be grouped into one commit when they share a
  phase and gate.
- Any algorithm rewrite, grammar promotion, or runtime behavior change should
  be committed separately with its before/after evidence.
- Each batch should append a commit-ready summary to
  `tmp/gen-z-changelog.txt`, then rewrite that file into the final commit
  message before committing.
- Do not run broad heavy suites by default. Use focused filters first, then the
  accepted bounded release gate when the batch affects promoted behavior.
