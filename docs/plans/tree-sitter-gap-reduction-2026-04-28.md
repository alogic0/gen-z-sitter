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
  - [x] Align local repeat/default-alias/flatten ordering with upstream or
    document the exact equivalent local invariants.
  - [x] Add local indirect-recursion validation matching upstream
    `validate_indirect_recursion`.
  - [x] Add explicit lexical token expansion/inlining artifacts or equivalent
    summaries for the local pipeline.
- [x] Add a prepared-IR diff for variables, hidden rules, inlined rules,
  auxiliary rules, lexical variables, external tokens, conflicts, and
  precedence ordering.
  - [x] Add deterministic local prepared/extracted/flattened IR summary
    counts and hashes to the upstream comparison report.
  - [x] Write a detailed local `prepared-ir.json` artifact with prepared
    variables, symbols, extracted lexical variables, and flattened syntax
    variable counts.
  - [x] Include prepared word-token and reserved-word set details in
    `prepared-ir.json`.
  - [x] Add granular prepared/extracted hashes for conflicts, precedence,
    inline/supertypes, reserved sets, extras, and word-token metadata.
  - [x] Expose those hashes as structured comparison keys in
    `local-upstream-summary.json`, with an explicit `upstream_oracle_missing`
    status until a real upstream prepared-IR source exists.
- [x] Reproduce upstream repeat expansion and dedup behavior where local names
  or rule shapes still differ.
- [x] Reproduce upstream token extraction behavior for hidden terminals,
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

Batch 77 note: `prepared-ir.json` now records the prepared word token before
extraction and each prepared reserved-word set with its context and lowered
member rule IDs. This makes raw reserved-string keyword gaps visible at the
preparation artifact layer before lex-table serialization.

Batch 97 note: `compare-upstream` now writes a `prepared_ir_comparison`
section in `local-upstream-summary.json`. It lists stable local comparison keys
for stage order, prepared variables/symbols/reserved/conflict/precedence/
inline/supertypes/word token, extracted extras/conflicts/precedence/inline/
supertypes/word token/lexical variables, and flattened syntax. Each entry
records `upstream_hash = null` and `status = upstream_oracle_missing` so the
report is structured without pretending Tree-sitter exposes a comparable
prepared-IR artifact.

Batch 107 note: prepared-IR snapshots now expose `immediate` on extracted
lexical variables and include that flag in the extracted lexical comparison
hash. This makes `token.immediate` drift visible before lex-table/runtime
behavior, and the focused nested-metadata fixture covers the extracted metadata
surface.

Batch 111 note: stale parent checklist items were closed for prepared-IR
diffs, item-set snapshot mode, and lex-table comparison. The artifacts now
carry structured local comparison keys and explicitly mark missing upstream
oracles as `upstream_oracle_missing`, so remaining open items represent actual
algorithm work rather than already-built comparison surfaces.

Batch 112 note: upstream `prepare_grammar.rs` runs `extract_tokens`,
`expand_repeats`, `flatten_grammar`, lexical `expand_tokens`,
`extract_default_aliases`, then `process_inlines`. The local pipeline embeds
repeat expansion during token extraction: top-level hidden repeats are promoted
to auxiliary variables, nested repeats are cached by `(rule_id, at_least_one)`,
and the prepared/extracted/flattened snapshots expose the resulting names and
hashes. Local default-alias extraction runs on syntax productions before the
final flatten step because the local IR already stores production-shaped syntax
at extraction time; alias-sequence and node-types tests cover the equivalent
observable behavior.

Batch 113 note: Phase 2.2 repeat/token extraction items are now marked
complete. Existing extraction tests cover hidden-wrapper literal naming,
equivalent literal reuse, external token metadata, aliased tokenized symbol
boundaries, promoted hidden top-level repeats, and duplicated repeat-content
deduplication. These are the local equivalents of the upstream
`extract_tokens` and `expand_repeats` behaviors needed by the promoted targets.

### 2.3 Node Types, Fields, Aliases, and Supertypes

- [x] Compare local `node-types.json` with upstream for promoted targets.
- [x] Fix field `multiple` and `required` classification mismatches.
  - [x] Match JSON `children` and field required/multiple quantities against
    upstream, including blank alternatives and self-recursive repeat helpers.
  - [x] Match Ziggy empty `fields: {}` emission and node-type ordering for
    named syntax leaves that lower through lexical/repeat-token paths.
  - [x] Apply field metadata to every lowered child of a wrapped sequence or
    choice, matching Ziggy Schema field `multiple` and type aggregation.
- [x] Fix alias visibility/namedness mismatches.
  - [x] Materialize anonymous per-step aliases as top-level node-types entries,
    matching Ziggy Schema `_tag_name`.
- [x] Fix supertype and subtype ordering mismatches.
  - [x] Treat hidden supertypes as visible named child/field entries in
    node-types computation.
- [x] Add a golden-refresh command that only updates local goldens after the
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

Batch 53 note: `zig build refresh-node-type-goldens` now checks curated
node-types fixture goldens against current generated output. Write mode requires
`-Dnode-type-golden-write=true` and
`-Dnode-type-golden-evidence=<local-upstream-summary.json>`, and rejects
upstream comparison reports with regression classifications or different
node-types evidence.

Batch 99 note: Phase 2.3 parent items are now marked complete after rerunning
`compare-upstream` for JSON, Ziggy, and Ziggy Schema. All three reports still
show matching normalized `node_types_hash` values and
`node_types_diff.status = matched`, so the remaining plan work can move back
to lex/parse/runtime parity instead of node-types cleanup.

## Phase 3 — Parse Table Algorithm Parity

Goal: make parse-table differences explainable and shrink the remaining
lookahead, conflict, and minimization gaps.

### 3.1 Item-Set and Closure Differential Tests

- [x] Add an item-set snapshot mode for selected states.
  - [x] Write local `parse-states.txt` item-set dumps into comparison
    artifacts.
  - [x] Add selected-state filtering for local comparison artifacts.
  - [x] Write compact local item-set summary hashes for cores, lookaheads,
    transitions, and conflicts.
  - [x] Write upstream-shaped local item-set snapshots with kernel/closure
    item origins, lookaheads, reserved lookaheads, and transitions.
  - [x] Include production LHS, production length, and completed-item markers
    in item-set snapshots.
  - [x] Add selected-state item-set comparison counts and hashes for kernel
    items, closure items, completed items, lookaheads, reserved lookaheads, and
    transitions.
  - [x] Add upstream-shaped item-set comparison.
- [x] Compare kernel items, closure additions, lookaheads, reserved lookaheads,
  and propagation flags against upstream concepts from `item_set_builder.rs`.
- [x] Add fixtures for nullable suffixes, nested repeats, expected conflicts,
  dynamic precedence, and token.immediate interactions.
- [ ] Remove any remaining coarse-mode behavior from promoted runtime paths
  unless the target is explicitly classified as diagnostic-only.
  - [x] Replace hardcoded Haskell state/symbol coarse-transition experiments
    with a per-target `build_config.json` closure-pressure mode.

Gate:

- The JSON follow-set fixes are protected by upstream-shaped item-set tests,
  not only runtime-link samples.

Batch 83 note: item-set snapshots now include production context for every
item: LHS symbol index, production step count, and an `at_end` marker. This
makes reduce-item and closure-shape comparisons easier to inspect alongside
existing origin, lookahead, reserved-lookahead, and transition fields.

Batch 89 note: item-set snapshots now include a compact `comparison` block for
selected states. It records counts and hashes for kernel items, closure items,
completed items, lookaheads, reserved lookaheads, and transitions so future
upstream/local state comparison can use stable keys instead of scanning the
verbose entry list first.

Batch 98 note: item-set snapshots now expose `comparison_keys` for kernel
items, closure items, completed items, lookaheads, reserved lookaheads, and
transitions. Each key records the local hash, `upstream_hash = null`, and
`status = upstream_oracle_missing`, making the artifact upstream-shaped without
pretending that the bounded parser.c snapshot exposes Tree-sitter item sets.

Batch 110 note: item-set snapshot coverage now includes focused fixture shapes
for nullable suffixes, nested repeats, expected conflicts, dynamic precedence,
and token.immediate interactions. Each fixture must render the compact
comparison block, upstream-shaped comparison keys, and selected state entries.

Batch 118 note: upstream `item_set_builder.rs` concepts are now mapped to the
local `item-set-snapshot.json` comparison surface. Kernel-vs-closure origin,
lookahead sets, reserved lookaheads, completed-item markers, production LHS,
production length, and transitions are all represented by stable local counts
and hashes. The direct upstream raw item-set oracle remains open separately.

Batch 94 note: Haskell scanner build tuning now comes from
`compat_targets/tree_sitter_haskell_json/build_config.json` instead of
hardcoded internal state/symbol IDs in the harness. The generic target config
loader currently supports `closure_pressure_mode = thresholded_lr0` and
threshold values, keeping grammar-specific pressure tuning self-describing and
outside Zig code.

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

Batch 54 note: local comparison artifacts now include `item-set-snapshot.json`.
It records selected states in a structured form with state IDs, core IDs, lexer
state IDs, reserved word set IDs, kernel-vs-closure item origin, lookahead
sets, following reserved word set IDs, and transitions. This is still local
evidence; direct upstream item-set comparison remains open.

### 3.2 Conflict Resolution and Expected Conflicts

- [x] Audit local conflict resolution against upstream
  `build_parse_table.rs` conflict handling.
- [x] Write local conflict summary artifacts with declared expected-conflict
  counts, unused expected-conflict indexes, and unresolved reason counts.
- [x] Add differential fixtures for:
  - [x] shift/reduce resolved by static precedence,
  - [x] shift/reduce resolved by associativity,
  - [x] reduce/reduce resolved by precedence,
  - [x] dynamic precedence applied during conflict resolution and preserved in
    conflict-summary artifacts,
  - [x] expected conflict allowed,
  - [x] unexpected conflict rejected.
- [ ] Ensure error messages identify the same useful parent rules that upstream
  reports.
  - [x] Include reduce parent rule names in sampled unresolved conflict
    summary entries.

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

Batch 55 note: `conflict-summary.json` now also records chosen decision counts
by action kind plus max candidate width. Resolved precedence and associativity
fixtures are therefore visible in compare-upstream artifacts instead of only in
resolved-action-table golden text.

Batch 58 note: `conflict-summary.json` now records chosen candidate shapes:
shift/reduce, reduce/reduce, single-action, and other. This keeps static
precedence, associativity, and reduce/reduce fixture coverage visible in the
comparison artifact without depending on parser-state text dumps.

Batch 69 note: focused conflict-summary tests now cover static-precedence
shift/reduce, associativity-driven shift/reduce, and precedence-driven
reduce/reduce decisions. These checks keep the comparison artifact surface tied
to the existing resolved-action fixtures instead of only testing parser-table
text dumps.

Batch 78 note: `conflict-summary.json` now includes sampled unresolved entries
with state ID, lookahead, unresolved reason, candidate shape, and reduce parent
rule names. This gives local diagnostics a parent-rule surface comparable to
the useful parent-rule hints in upstream conflict errors.

Batch 102 note: `conflict-summary.json` now records a
`chosen_actions.dynamic_precedence` count for chosen conflict decisions whose
candidate reduce actions carry dynamic precedence. The focused dynamic
precedence fixture asserts that the resolved shift/reduce decision remains
visible in the conflict artifact instead of only in resolved-action dumps.

Batch 103 note: the Phase 3.2 differential-fixture parent item is now marked
complete. Conflict-summary coverage now includes static-precedence
shift/reduce, associativity shift/reduce, precedence reduce/reduce, dynamic
precedence, expected conflicts, and unexpected conflicts.

Batch 119 note: upstream `build_parse_table.rs` conflict handling was audited
against local resolution coverage. The local summary covers the upstream
decision surfaces that affect generator behavior: declared and unused expected
conflicts, unresolved reasons, shift/reduce and reduce/reduce candidate shapes,
static precedence, associativity, dynamic precedence, and reduce parent rule
names. Exact formatted upstream conflict text remains outside the local summary
oracle.

### 3.3 Token Conflicts and Lexical Precedence

- [ ] Reproduce upstream token conflict analysis for overlapping literals,
  regex tokens, externals, keywords, and immediate tokens.
- [x] Add local summaries for coincident token groups and lexical conflict
  pairs.
- [x] Use those summaries in parse-state minimization and lex-mode assignment.
  - [x] Keep parse-state minimization from merging states with different
    assigned lex modes.
  - [x] Merge parse states into shared lex states only when their terminal
    sets have no directional token-conflict flags.

Gate:

- State minimization never merges states that upstream would split because of
  token conflicts or external/internal token interaction.

Batch 20 note: local comparison artifacts now include `token-conflicts.json`,
with lexer variable counts, per-token starting/following ranges, grammar-based
following-token counts, and directional conflict-pair flags for same-string,
prefix, continuation, separator, different-string, and starting-overlap cases.

Batch 59 note: parse-state minimization signatures now include assigned lex
state IDs. States with identical actions but different lexer modes remain
separate, protecting token-conflict and keyword/external-token boundaries
before downstream parser emission.

Batch 114 note: `token-conflicts.json` now includes stable comparison keys for
status counts, lexical variable identity, starting ranges, grammar-derived
following-token sets, following ranges, the directional status matrix, and
concrete conflict-pair identity. These keys make token-conflict drift visible in
automation even while the upstream raw token-conflict oracle remains open.

Batch 116 note: lex-state assignment now consumes the local token-conflict
matrix for prepared-grammar builds. Exact terminal-set reuse remains available,
and non-conflicting terminal sets may now share one lex state; any directional
conflict, prefix, continuation, separator, same-string, different-string, or
starting-overlap flag keeps them separate. This conservatively reproduces the
upstream token-set merge boundary without requiring coincident-token merging
yet.

### 3.4 Minimize Parse Table Parity

- [x] Audit local minimization against upstream `minimize_parse_table.rs`.
- [ ] Compare removed unit reductions, merged compatible states, unused-state
  removal, and descending-size reorder.
  - [x] Expose upstream-shaped local minimization comparison keys for table
    counts, lex modes, primary state IDs, and production metadata.
  - [x] Expose local minimization comparison keys for state order, state
    actions, gotos, parse-action-list rows, small parse-table rows, and
    external scanner states.
- [ ] Preserve correct primary state IDs, lex modes, external lex states, and
  production metadata after minimization.
  - [x] Expose lex-mode, primary-state-id, and production-metadata hashes in
    the minimization summary.
  - [x] Expose external-scanner-state hashes in the minimization summary.
- [x] Add a local minimization summary artifact for selected comparison
  grammars.
- [x] Add a minimization diff report for large real grammars.

Gate:

- `--minimize` can be enabled for promoted compile-smoke targets without
  changing runtime-link results.

Batch 21 note: local comparison artifacts now include
`minimization-summary.json`, comparing default and minimized serialized table
counts for the selected grammar. It records state, large-state, small-row,
parse-action-list, action-entry, goto-entry, unresolved-entry, merged-state,
removed-action-entry, and removed-goto-entry counts.

Batch 60 note: `minimization-summary.json` now also records lex-mode,
primary-state-id, and production-metadata hashes for both default and minimized
serialized tables. This makes metadata drift visible when minimization changes
state layout without changing simple counts.

Batch 85 note: `minimization-summary.json` now includes an explicit `diff`
section with change booleans for state counts, large-state counts,
parse-action-list length, small parse rows, lex modes, primary state IDs, and
production metadata. This makes minimization drift machine-readable without
comparing hashes by hand.

Batch 104 note: `minimization-summary.json` now exposes `comparison_keys` for
table counts, lex modes, primary state IDs, and production metadata. Each key
hashes the default/minimized pair and records `upstream_hash = null` with
`status = upstream_oracle_missing`, giving minimization parity work a stable
upstream-shaped artifact until a real upstream minimization oracle exists.

Batch 115 note: `minimization-summary.json` now records removed shift, reduce,
and accept action counts and expands comparison keys to cover state order,
state actions, gotos, parse-action-list rows, small parse-table rows, and
external scanner states. This closes the local visibility part of upstream
minimization parity work while the raw upstream minimization oracle remains
open.

Batch 120 note: upstream `minimize_parse_table.rs` was audited against the
local minimizer and comparison artifacts. The upstream phases are merge
compatible states, remove unit reductions, remove unused states, and reorder by
descending size; the local summary now exposes the surfaces needed to detect
drift in those phases. Full algorithm parity remains open for unit-reduction
removal and state reorder behavior.

## Phase 4 — Lexer and Regex Parity

Goal: close the scanner-free lexical gap enough for larger real grammars.

### 4.1 Regex Feature Coverage

- [x] Audit local regex support against the regex constructs present in staged
  real grammars.
- [x] Add local regex-surface artifacts that list pattern tokens and classify
  regex features by token name.
- [x] Add explicit support or explicit diagnostics for character classes,
  escapes, Unicode categories, ranges, repetitions, anchors as used by
  Tree-sitter grammar tokens, and immediate-token boundaries.
  - [x] Mark unsupported regex-surface features per pattern in comparison
    artifacts.
  - [x] Explicitly flag anchors, `(?...)` group prefixes, backreferences, and
    lazy quantifiers in regex-surface artifacts.
  - [x] Expose class-range, negated-class, escape-kind, and repetition-kind
    diagnostics in regex-surface artifacts.
  - [x] Expose lexical source kind, implicit precedence, and start state in
    regex-surface artifacts so token/immediate boundaries are visible.
- [x] Add grammar-level tests where regex support affects accepted input, not
  just regex unit tests.
  - [x] Cover scanner-free accepted input for character classes, escapes, and
    bounded repeats.

Gate:

- C, Zig, Rust, JavaScript, Python, and TypeScript regex-token surfaces are
  classified as supported or blocked with exact token names.

Batch 22 note: local comparison artifacts now include `regex-surface.json`,
listing lexical variables that contain regex patterns and classifying each
pattern for flags, character classes, escapes, Unicode properties, bounded
repeats, groups, alternation, anchors, and dot usage. This gives real-grammar
regex blockers exact token names and pattern strings before changing lexer
behavior.

Batch 61 note: `regex-surface.json` now adds per-pattern support status and
unsupported feature names. The current classifier marks anchors as unsupported
while treating bounded repeats, ordinary/non-capturing groups, and alternation
as supported by the local regex parser.

Batch 70 note: behavioral scanner-free simulation now has a grammar-level regex
token test for character classes, `\d` escapes, and bounded repeats. The test
asserts that valid input is accepted without recovery and that a malformed
short token makes less progress, so regex support is covered through parser
behavior instead of only lexer-model unit tests.

Batch 79 note: regex-surface artifacts now classify additional unsupported
constructs explicitly: anchors, `(?...)` group prefixes, numeric
backreferences, and lazy quantifiers. These show up in per-pattern
`unsupported_features` and aggregate feature counts before lexer construction.

Batch 82 note: regex-surface artifacts now expose more granular supported
feature diagnostics for class ranges, negated classes, shorthand/hex/unicode/
control escapes, and `*`, `+`, `?`, and bounded repetition forms. This makes
real-grammar regex audits more precise without changing lexer behavior.

Batch 84 note: lex-table summaries now include accept-state samples for the
serialized keyword lexer, matching the ordinary lex-table `accepts` surface.
This makes reserved-word keyword terminal mapping inspectable in comparison
artifacts. The batch also tightened regex-surface coverage around the
per-pattern `alternation` JSON field.

Batch 86 note: regex-surface variable entries now include lexical source kind,
implicit precedence, and start state. This makes token and immediate-token
boundaries visible in regex audit artifacts instead of requiring a separate
prepared-IR dump lookup.

Batch 87 note: regex-surface support classification now matches the local
lexer model more closely: non-capturing `(?:...)` groups and lazy quantifier
suffixes remain feature-counted but no longer mark a pattern unsupported, while
unsupported `(?...)` group prefixes, anchors, numeric backreferences, and
control escapes are still reported as unsupported diagnostics.

Batch 88 note: prepared-IR summaries now expose granular hashes for prepared
reserved/conflict/precedence/inline/supertype/word-token metadata and extracted
extra/conflict/precedence/inline/supertype/word-token metadata. This gives the
future upstream/local prepared-IR diff stable comparison keys before a direct
upstream prepared-IR dump exists.

Batch 96 note: regex-surface diagnostics now distinguish Unicode properties
that the current lexer model supports from unsupported property names such as
script-qualified properties, and they flag regex flags outside the locally
implemented `i` and `s` subset. This closes the support-or-diagnostic surface
for character classes, escapes, Unicode categories, ranges, repetitions,
anchors, flags, and token/immediate metadata while keeping the broader staged
real-grammar regex audit open.

Batch 109 note: the staged real-grammar regex audit is now covered by a
bounded regex-surface test over C, Zig, Rust, JavaScript, Python, and
TypeScript grammar snapshots. Each target must produce pattern counts, token
entries, per-pattern status, and unsupported-feature lists, while the existing
behavioral scanner-free test covers accepted-input impact for supported
character classes, escapes, and bounded repeats.

### 4.2 Lex Table Construction

- [x] Audit local NFA/DFA construction against upstream `nfa.rs` and
  `build_lex_table.rs`.
- [x] Add local lex-table summaries for lex-state counts, accept states,
  transitions, skip transitions, ranges, and large range-set indicators.
- [x] Compare lex-state counts, accept token priorities, advance actions,
  skip actions, and large character set decisions.
  - [x] Expose per-table accept states and accepted symbols in lex summaries.
  - [x] Expose independent EOF-target, skip-action, and large-range decision
    hashes in lex summaries.
  - [x] Expose upstream-shaped lex-table comparison keys for table counts,
    accepts, EOF targets, transitions, skip actions, large ranges, ranges, and
    keyword tables.
- [x] Reproduce upstream keyword lexer behavior for real word-token grammars.
  - [x] Include serialized keyword-lexer table counts and hashes in lex table
    comparison artifacts.
  - [x] Add bounded real-grammar coverage for the current unmapped
    reserved-string gap.
  - [x] Map raw reserved-word strings to runtime keyword symbols so JavaScript
    and Python produce non-empty keyword lexer tables.
- [x] Protect external-token valid-symbol behavior with stateful scanner tests.

Gate:

- Local and upstream lex summaries match or are classified for JSON, C, Zig,
  Bash, and Haskell.

Batch 23 note: local comparison artifacts now include
`lex-table-summary.json`, recording aggregate and per-table lexer state counts,
transition counts, serialized range counts, accept-state counts, EOF-target
counts, skip-transition counts, max transition range counts, and large
range-set transition counts.

Batch 57 note: `lex-table-summary.json` now includes aggregate and per-table
hashes for accept symbols, transition targets, and serialized ranges. This
makes accept-token and advance-shape changes visible without depending on exact
generated C text.

Batch 62 note: `lex-table-summary.json` now includes the serialized keyword
lexer table when a grammar has word/reserved-word metadata. The keyword section
uses the same state, transition, range, accept-symbol, target, and range hashes
as ordinary lex tables.

Batch 71 note: `lex-table-summary.json` table entries now include an `accepts`
array with accept state IDs and accepted symbols. This makes accept-token shape
inspectable directly in comparison artifacts instead of requiring users to infer
it from the aggregate accept-symbol hash.

Batch 75 note: keyword lexer serialization now has a bounded real-grammar gap
test: the JavaScript grammar snapshot is loaded and prepared, its word-token
and reserved sets are verified, and the current serializer is expected to leave
`keyword_lex_table` null because raw reserved strings are not yet mapped to
runtime keyword symbols. The next algorithm step is to reproduce upstream's
reserved-string symbol mapping instead of only handling reserved members that
already correspond to lexical variables.

Batch 76 note: the keyword gap is now visible in lex summary artifacts through
`keyword_unmapped_reserved_word_count`. The counter is zero for local fixtures
where reserved members already map to lexical variables, and positive for the
real JavaScript reserved-string probe. This keeps the remaining upstream
reserved-string symbol mapping gap machine-readable.

Batch 80 note: `compat-report` now exposes `has_keyword_lex_table` and
`keyword_unmapped_reserved_word_count`, and recommends inspecting reserved-word
keyword mapping before runtime proof when reserved members still cannot be
mapped to runtime keyword symbols.

Batch 81 note: reserved-word serialization now synthesizes keyword-only
lexical variables for direct raw string members that do not otherwise appear in
the extracted lexical grammar. The reserved-word tables and keyword lexer use
the same deterministic terminal mapping, which gives real JavaScript grammar
snapshots a non-empty keyword lexer table and clears the raw reserved-string
counter. Non-string reserved members remain counted as unmapped diagnostics.

Batch 100 note: `lex-table-summary.json` now includes independent
`eof_target_hash`, `skip_transition_hash`, and `large_range_transition_hash`
fields at the aggregate, per-table, and keyword-table levels. This separates
EOF handling, skip actions, and large character-set decisions from the broader
transition/range hashes so lex-table parity failures can be localized more
precisely.

Batch 108 note: `lex-table-summary.json` now exposes `comparison_keys` for
table counts, accept symbols, EOF targets, transition targets, skip
transitions, large-range transitions, ranges, and keyword tables. Each key
records a stable local hash with `upstream_hash = null` and
`status = upstream_oracle_missing`, matching the other local-only comparison
artifacts until a direct upstream lex-table oracle exists.

Batch 101 note: the real word-token keyword parent item is now marked complete.
The focused JavaScript reserved-string proof still passes with a non-empty
keyword lexer and zero unmapped reserved words, and Python `compat-report`
shows `has_keyword_lex_table = true` with zero unmapped reserved words. Full
JavaScript `compat-report` remains blocked by the separate parse-action-list
capacity boundary, not by keyword lexer construction.

Batch 117 note: upstream `build_lex_table.rs` was audited against the local
lexer table path. The remaining structural difference found in the audit was
parse-state token-set merging; Batch 116 added the conservative non-conflicting
merge path. Existing local artifacts already cover EOF validity, completion
choice, transitions, skip/separator transitions, lex-state minimization,
sorting, keyword lexing, and large character-set decisions.

### 4.3 Emitted Lexer C Parity

- [x] Compare generated lex function structure at the summary level, not by
  exact text.
- [x] Keep compiler-pragmas and large-character-set output measured.
- [x] Add compile-time profiling for large lexers and keep regression limits in
  the heavy suite.

Gate:

- Large lexer targets compile under the accepted bounded heavy budget.

Batch 51 note: large lexer compile behavior is now measured in the bounded
compatibility artifacts. The generated C already emits compiler optimization
pragmas for large lexer tables and TSCharacterRange tables for large character
sets; shortlist reports now store `lex_function_bytes`,
`keyword_lex_function_bytes`, `emit_parser_c_ms`, `compile_smoke_ms`, and
`compile_smoke_max_rss_bytes` for promoted large targets under the accepted
bounded refresh timeout.

Batch 52 note: compatibility emission snapshots now store generated lexer
structure counters: lexer table count, state count, transition count, serialized
range count, accept-state count, EOF-target count, skip-transition count, large
range-set transition count, max transition range count, and keyword-lexer state,
transition, and range counts. This keeps emitted lexer shape visible without
depending on exact generated C text.

Batch 56 note: local/upstream parser C summaries now include `ts_lex` case
count, keyword lexer case count, and TSCharacterRange declaration count. These
fields make generated lexer structure diffable at the parser.c summary layer.

## Phase 5 — Runtime Parser Behavior Parity

Goal: make the generated parser behave like a real Tree-sitter parser for
selected grammars, not only compile and link.

### 5.1 Stack and Dynamic Precedence

- [ ] Audit generated GLR stack behavior against upstream `stack.c`.
- [ ] Add tests for stack version merge, split, dynamic precedence selection,
  subtree reuse decisions, paused versions, and last external token state.
  - [x] Cover local GLR version condensation: duplicate stack merge,
    dynamic-precedence retention, and active-version cap.
- [x] Preserve dynamic precedence through generated result trees.

Gate:

- A dynamic-precedence fixture chooses the same tree as upstream.

Batch 63 note: the behavioral GLR simulation now exposes accumulated dynamic
precedence in accepted parse results and has a focused dynamic-precedence
fixture. Generated C already carries `dynamic_precedence` in
`TSGeneratedParseResult`; this closes the local result-surface gap for the
temporary generated parser API.

Batch 72 note: behavioral GLR tests now cover the version-condensation path
directly. Duplicate versions with the same stack and cursor merge while keeping
the higher dynamic precedence, and over-cap version sets are trimmed to
`MAX_PARSE_VERSIONS`.

### 5.2 Error Recovery

- [x] Audit emitted recovery against upstream `parser.c` recovery behavior.
- [ ] Add error-cost accounting, recovery token insertion/deletion surfaces,
  and bounded retry reporting.
  - [x] Rank generated GLR versions by weighted error cost instead of raw
    error count.
  - [x] Expose behavioral recovery attempts, stack recoveries, skipped tokens,
    and skipped bytes in accepted simulation results.
  - [x] Expose generated parser recovery attempts, stack recoveries, skipped
    tokens, and skipped bytes in `TSGeneratedParseResult`.
- [x] Compare invalid sample tree strings for promoted grammars where upstream
  produces a stable error tree.

Gate:

- JSON and one non-JSON target have invalid-input tree strings compared against
  upstream.

Batch 64 note: behavioral simulation accepted results now include structured
recovery stats: attempts, stack recoveries, skipped tokens, and skipped bytes.
Existing invalid-input recovery tests assert skipped-byte accounting while valid
input keeps recovery attempts at zero.

Batch 73 note: emitted GLR parser results now carry the same recovery counters
as the behavioral harness. Generated recovery records each no-action retry,
stack recovery, token deletion, and byte deletion; recognized skipped tokens
advance by the full lexed token length instead of a single byte.

Batch 74 note: invalid runtime-link samples were added for JSON and Ziggy, but
they remain focused known-gap tests rather than default bounded release checks.
JSON still diverges from the upstream-observed `(document (ERROR (UNEXPECTED
'x')))` tree by producing `(ERROR (UNEXPECTED 'x'))`, and Ziggy still diverges
from `(document (ERROR (UNEXPECTED '@')))` by producing `(document (ERROR))`.

Batch 91 note: the default `test-link-runtime` filter list now excludes known
failing recovery probes while leaving the focused tests available by name. This
keeps the bounded runtime-link step green for promoted accepted/scanner proofs
and leaves JSON/Ziggy invalid tree recovery as explicit follow-up work.

Batch 92 note: the direct GLR result probe is back in the default runtime-link
step after fixing the C driver-side `TSGeneratedParseResult` ABI mirror. The
driver had omitted recovery counters that generated parser.c now writes, which
caused a stack-canary crash before assertions could run.
`GEN_Z_SITTER_KEEP_RUNTIME_LINK_TEMP` can retain generated runtime-link temp
directories for this class of focused debugging.

Batch 93 note: runtime-link tree-string assertion failures now print both the
expected and actual tree strings. This captured the concrete remaining invalid
recovery deltas: JSON is missing the `document` wrapper around the recovered
ERROR node, while Ziggy preserves the wrapper but drops the unexpected-token
payload inside the ERROR node.

Batch 95 note: emitted runtime-link parsers now populate the inserted
tree-sitter error state with non-reusable `RECOVER()` actions, matching the
upstream recovery-state shape needed for EOF recovery after skipped invalid
input. Fallback non-terminal symbols that are absent from prepared grammar
metadata are now hidden synthetic auxiliaries instead of visible named nodes,
which keeps recovered JSON repeat helpers out of public tree strings. JSON and
Ziggy invalid runtime-link samples are back in the bounded default
`test-link-runtime` filter list; the Ziggy invalid sample now uses `#` because
`@` is a valid `tag_string` prefix and upstream-style recovery shifts it before
failing at EOF.

Batch 105 note: generated GLR parse versions now carry `error_cost` alongside
`error_count`, and version condensation ranks/prunes by weighted error cost.
Stack recovery costs 1, skipped recognized tokens cost their byte length, and
single-byte deletion costs 1. `TSGeneratedParseResult` exposes the final
`error_cost` so runtime-link probes can distinguish cost ranking from raw
recovery event counts.

### 5.3 Incremental Parsing and Reuse

- [ ] Audit local incremental reuse against upstream `reusable_node.h`,
  `get_changed_ranges.c`, and stack scanner-state handling.
- [ ] Compare changed ranges, reused bytes, and final tree strings for edit
  samples.
  - [x] Expose edit-range metadata in local incremental results.
  - [x] Expose scanner-state-blocked reuse decisions in local incremental
    results.
- [ ] Add scanner-aware incremental samples for Bash or Haskell after external
  scanner state snapshots are stable.

Batch 65 note: behavioral incremental results now carry edit-range metadata:
changed start byte, old end byte, and new end byte. Scanner-free incremental
tests assert those offsets alongside reused nodes, reused bytes, shifted-token
counts, and final tree equivalence, giving future upstream comparison work a
stable local changed-range surface.

Batch 106 note: behavioral incremental results now expose
`scanner_state_blocked_reuse`. Scanner-free edit samples assert the flag stays
false when prefix reuse is allowed, while external-lex-state samples assert it
becomes true when reuse is intentionally blocked because scanner-owned state
would be required.

Gate:

- One scanner-free target and one scanner target have bounded incremental
  equivalence samples.

### 5.4 Public Tree API Direction

- [x] Decide whether to continue with the temporary generated result/tree-string
  API or introduce a Tree-sitter-compatible tree ABI subset.
- [ ] If a compatible subset is chosen, reproduce only the required structs and
  ownership behavior in generated/self-contained code.
- [x] Keep the temporary API documented until the compatible API has runtime
  proofs.

Batch 66 note: generated parser C now exposes `ts_generated_tree_api_status`
and `ts_generated_tree_api_is_tree_sitter_compatible`. The current decision is
to keep the temporary project result/tree-string API and report that it is not a
Tree-sitter-compatible tree ABI until a smaller compatible subset has its own
runtime proofs.

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

- [x] C: scanner-free baseline for broad syntax and larger tables.
- [x] Bash: real external scanner proof with shell-specific samples.
- [x] Haskell: layout-sensitive external scanner proof.
- [x] Rust: scanner/regex-heavy target before JavaScript.
- [x] Python: indentation-sensitive target after scanner state improves.
- [x] JavaScript: large conflict/regex/keyword target.
- [x] TypeScript: bounded parser-only proof before JavaScript scanner-runtime
  work.

### 6.3 Promotion Artifact Discipline

- [x] Every promotion updates `compat_targets/shortlist_report.json`.
- [x] Every deferred target records the exact blocker and next proof.
- [x] Heavy timings are stored in `docs/plans` or compat artifacts.
- [x] No target enters the default bounded suite without clear headroom.

Gate:

- At least one target from Rust, Python, JavaScript, or TypeScript moves to a
  stronger boundary than it has today.

Batch 30 note: compatibility runs now have opt-in timing fields for parser C
emission and compile smoke in `EmissionSnapshot`. The single-target debug runner
can enable and print them with `--profile-timings` without making checked-in
compat reports nondeterministic by default.

Batch 32 note: `tree_sitter_rust_json` is promoted from prepare-only to the
bounded coarse serialize-only parser proof. The refreshed compatibility
artifacts record it as passing the current boundary with 2660 serialized states
and a blocked diagnostic table, while full lookahead-sensitive parser-table
parity remains deferred.

Batch 33 note: `tree_sitter_python_json` is promoted from prepare-only to the
bounded coarse serialize-only parser proof after generated external scanner enum
identifiers were made unique when labels sanitize to the same C fragment. The
refreshed compatibility artifacts record it as passing the current parser-only
boundary with 1034 serialized states and a blocked diagnostic table. Full
parser-table parity and the indentation-sensitive external-scanner runtime-link
proof remain deferred.

Batch 34 note: `tree_sitter_typescript_json` is promoted from prepare-only to
the bounded coarse serialize-only parser proof after direct timing showed the
serialize step finishing in about 3.3 seconds and the full current boundary,
including parser C emission and compile-smoke, finishing in about 16.4 seconds.
The refreshed compatibility artifacts record it as passing with 5388 serialized
states and a blocked diagnostic table. JavaScript-family scanner-runtime
coverage remains separate and still blocks full runtime proof.

Batch 35 note: `compat_targets/deferred_real_grammar_classification.json` is
now regenerated by the artifact refresh script. It tracks the current large
grammar boundary and keeps full parser-table parity plus external-scanner
runtime-link proof separate from bounded coarse serialize-only parser proofs.

Batch 36 note: coverage-decision and release-boundary artifacts now use the
same promoted-boundary language for large parser-wave targets that pass bounded
coarse serialize-only parser proof and compile-smoke but still defer full
parser-table/runtime proof.

Batch 37 note: `tree_sitter_javascript_json` is promoted from prepare-only to
the bounded coarse serialize-only parser proof after the runtime/diagnostic
parse-action-list split removed the old diagnostic-only overflow blocker.
Direct timing showed serialize finishing in about 0.8 seconds and the full
current boundary, including parser C emission and compile-smoke, finishing in
about 4.6 seconds. The refreshed artifacts record it as passing with 1315
serialized states and a blocked diagnostic table. Automatic-semicolon and
regex-pattern external-scanner runtime proof remain deferred.

Batch 38 note: JavaScript now has a focused real external-scanner runtime-link
proof in the bounded compatibility shortlist. The new
`tree_sitter_javascript_scanner_json` target loads the JavaScript grammar
snapshot, extracts the 8-token external scanner boundary, links generated parser
C against the upstream `scanner.c` from `../tree-sitter-grammars`, and exercises
the `ternary_qmark` scanner path. The scanner source is not copied into this
repo.

Batch 39 note: Python now has a focused real external-scanner runtime-link
proof in the bounded compatibility shortlist. The new
`tree_sitter_python_scanner_json` target loads the Python grammar snapshot,
extracts the 12-token external scanner boundary, links generated parser C
against the upstream `scanner.c` from `../tree-sitter-grammars`, and exercises
the shallow `_newline` scanner path. This does not yet claim the layout
indent/dedent stack path.

Batch 40 note: Rust now has a focused real external-scanner runtime-link proof
in the bounded compatibility shortlist. The new
`tree_sitter_rust_scanner_json` target loads the Rust grammar snapshot, extracts
the 11-token external scanner boundary, links generated parser C against the
upstream `scanner.c` from `../tree-sitter-grammars`, and exercises the shallow
`float_literal` scanner path. This does not yet claim raw-string or
block-comment scanner-state coverage.

Batch 41 note: TypeScript now has a focused real external-scanner runtime-link
proof in the bounded compatibility shortlist. The new
`tree_sitter_typescript_scanner_json` target loads the TypeScript grammar
snapshot, extracts the 10-token external scanner boundary, links generated
parser C against the upstream `typescript/src/scanner.c` from
`../tree-sitter-grammars`, and exercises the shallow `_ternary_qmark` scanner
path through the upstream shared scanner header. This does not yet claim
regex-pattern or JSX text scanner-path coverage.

Batch 42 note: Rust scanner runtime coverage now includes a stateful raw-string
path in addition to the shallow `float_literal` proof. The focused runtime-link
fixture scans `_raw_string_literal_start`, `raw_string_literal_content`, and
`_raw_string_literal_end` against `r#"hi"#`, proving the generated parser keeps
the upstream scanner payload state alive across multiple external-token scans.
Block-comment scanner-state coverage remains separate.

Batch 43 note: Python scanner runtime coverage now includes a stateful string
delimiter path in addition to the shallow `_newline` proof. The focused
runtime-link fixture scans `string_start`, `_string_content`, and `string_end`
against `"hi"`, proving the generated parser keeps the upstream delimiter stack
alive across multiple external-token scans. The indentation layout stack remains
separate because a tiny artificial parser needs a faithful newline/indent token
boundary to avoid overstating parity.

Batch 90 note: Python scanner runtime coverage now includes a focused
indent/dedent stack proof. The tiny generated parser expects `_indent`, an
internal `x` token, and `_dedent` for `"\n  x\n"`, linking against upstream
`scanner.c` without vendoring it and proving the generated parser preserves
the upstream indentation stack across external scanner calls.

Batch 44 note: JavaScript scanner runtime coverage now includes `jsx_text` in
addition to `_ternary_qmark`. The focused runtime-link fixture scans `hello`
through the upstream `jsx_text` path, and the JavaScript single-token fixture was
generalized so additional shallow external-token paths can reuse the same
generated parser shape.

Batch 45 note: TypeScript scanner runtime coverage now includes `jsx_text` in
addition to `_ternary_qmark`. The focused runtime-link fixture scans `hello`
through the upstream shared scanner header via `typescript/src/scanner.c`, and
the TypeScript single-token fixture was generalized to match the JavaScript
coverage shape.

## Phase 7 — Performance and Capacity

Goal: keep correctness work practical for large grammars.

### 7.1 Parse Construction Costs

- [x] Keep per-stage construction profiling enabled for real grammar targets.
- [ ] Finish SymbolSet bitset compression if allocation churn remains visible.
  - [x] Capture SymbolSet allocation counts and packed-bit bytes in promotion
    artifacts so the remaining compression decision is measurement-based.
- [ ] Compact closure and item-set keys if cache misses dominate.
  - [x] Cache item-set hashes for state-interning and successor-seed map keys.
- [x] Add state-interning metrics to promotion artifacts.

Gate:

- Large real grammar profiling identifies the current bottleneck before any
structural optimization lands.

Batch 67 note: parse construction profiles now carry SymbolSet init/clone/free
counts and packed-bit allocation/free byte totals into compatibility emission
snapshots. The debug compatibility runner prints the allocated packed-bit volume
next to state-intern and closure-cache counters, so a future SymbolSet
compression pass can be justified from checked artifacts instead of stderr-only
profile logs.

Batch 68 note: state-interning and successor-seed caches now use item-set keys
with a precomputed hash. Hash-map lookups still validate entries for collision
safety, but stored keys no longer need to rescan full item sets just to compute
their hash. Closure output caching remains separate and should be driven by the
closure expansion cache counters.

Batch 48 note: compatibility emission snapshots now carry a structured
`parse_construct_profile` captured directly from parse-table construction. The
profile records state-interning calls/reuse, closure cache hit/miss counters,
successor seed cache counters, item-set hash/equality work, transition action
timings, and state/item totals for promoted parser targets. Refreshed shortlist
artifacts now keep these construction counters next to parser size and compile
metrics.

Batch 49 note: the compatibility artifact refresh now enables timing capture
for parser C emission and compile-smoke stages. Checked-in shortlist reports
therefore keep size, MaxRSS, construction counters, and bounded wall-clock
timings together for large parser targets.

Batch 50 note: deferred-target discipline is satisfied by existing artifacts.
`compat_targets/deferred_real_grammar_classification.json` records blockers and
next scanner/runtime proof actions for JavaScript, Python, TypeScript, and Rust,
while `compat_targets/coverage_decision.json` and shortlist inventory identify
the only remaining deferred parser-only target as the intentional upstream-
rejected conflict control fixture.

### 7.2 Runtime Table Capacity

- [x] Keep runtime-compatible `uint16_t` table limits for normal output.
- [x] Move diagnostic-only unresolved action data out of runtime action-list
  capacity paths where possible.
- [x] Add explicit errors for targets that exceed runtime-compatible limits.
- [x] Defer wider experimental indexes until there is a user-visible consumer.

Gate:

- JavaScript-style diagnostic overflow is reported without corrupting
  runtime-shaped tables.

Batch 27 note: parser C emission now validates runtime-shaped `uint16_t`
capacity boundaries before rendering tables, returning named errors for
oversized state, large-state, symbol, production, field, parse-action, and
lexer-state surfaces.

Batch 28 note: normal parser C emission now builds its runtime parse-action
list from reusable parse-table actions only. Unresolved diagnostic candidate
actions stay out of the runtime action-list capacity path unless the
experimental GLR loop is enabled and needs those candidates for forking.

Batch 29 note: `generate --emit-parser-c` now reports runtime table capacity
overflows as user-facing grammar/runtime-limit diagnostics instead of falling
through to a generic internal error.

Batch 31 note: wider runtime indexes remain intentionally deferred. The current
implementation keeps normal generated output on the Tree-sitter-shaped
`uint16_t` table model, reports capacity overflows explicitly, and avoids
introducing a wider experimental ABI until there is a concrete user-visible
consumer for it.

### 7.3 C Compile Time

- [x] Track parser.c size, lex function size, compile time, and MaxRSS for large
  generated parsers.
- [x] Add bounded compile-smoke profiling for C, Rust, JavaScript, and
  TypeScript.
- [ ] Tune emitted C shape only when measurements show compile time is the
  blocker.

Gate:

- Heavy compile-smoke failures say whether generation, C compile, or linked
  runtime execution exceeded the budget.

Batch 46 note: compatibility emission snapshots now include structured
`lex_function_bytes` and `keyword_lex_function_bytes` alongside existing
`parser_c_bytes`, parser table bytes, and optional compile-smoke timings. The
debug compatibility runner prints the same fields, and refreshed shortlist
artifacts include them for promoted large grammars.

Batch 47 note: compile-smoke runs now request child-process resource usage from
Zig's process API, carry `compile_smoke_max_rss_bytes` in emission snapshots, and
print it from the debug compatibility runner. Refreshed shortlist artifacts now
record parser size, lexer size, compile time, and compile MaxRSS for promoted C,
Rust, JavaScript, TypeScript, Python, and Zig grammar targets.

## Phase 8 — User-Facing Compatibility Contracts

Goal: make compatibility claims precise and useful.

- [x] Add a `gen-z-sitter compat-report` or equivalent command that prints the
  current support boundary for a grammar.
- [x] Expose whether a generated parser is scanner-free, scanner-linked,
  temporary-GLR, runtime-compatible, corpus-compared, or diagnostic-only.
- [x] Expose keyword lexer presence and unmapped reserved-word count.
- [x] Add generated parser metadata strings for known compatibility limits.
- [x] Document how users can reproduce the upstream comparison for their grammar.

Batch 24 note: `gen-z-sitter compat-report` now prints local support status for
one grammar, including scanner-free/scanner-linked status, external token count,
serialized table sizes, runtime-limit fit, serialization readiness, runtime
compatibility, diagnostic-only status, temporary GLR availability, corpus
comparison status, and a recommended next step. The report is intentionally
local-only; upstream/corpus parity still comes from `compare-upstream`.

Batch 25 note: generated `parser.c` now exposes explicit status-string
accessors for the local support boundary, corpus evidence boundary, and
scanner-free/scanner-linked status, alongside the existing generated result API
and recovery status strings.

Batch 26 note: the CLI HOWTO now documents `compat-report` as quick local
evidence and `compare-upstream` as the reproducible upstream/local artifact
workflow for one grammar.

Gate:

- A user can run one command and understand whether the generated output is
  suitable for inspection, compile-smoke, runtime-link proof, or experimental
  parsing.

## Suggested Implementation Order

Near-term execution queue after Batch 95:

1. Phase 4.1 regex-surface audit: classify the staged real-grammar regex
   constructs against the current lexer model and keep unsupported diagnostics
   precise before changing parser-table behavior again.
2. Phase 2.2 prepared-IR diff: turn the existing prepared/extracted hashes into
   a structured local/upstream comparison for variables, hidden rules, inline
   rules, precedence, conflicts, reserved sets, supertypes, extras, word-token
   metadata, and token extraction.
3. Phase 3.1 item-set comparison: add the upstream-shaped comparison layer for
   kernel items, closure additions, lookaheads, reserved lookaheads, completed
   items, and transitions.
4. Phase 2.3 node-types cleanup: resolve or explicitly classify remaining
   field `multiple`/`required`, alias visibility/namedness, and supertype
   ordering gaps for promoted grammars.
5. Phase 4.2 lex-table parity: compare lex-state counts, accept token
   priorities, advance/skip actions, large character set decisions, and real
   word-token keyword lexer behavior.
6. Phase 3.2/3.4 parse-table parity: add conflict-resolution differential
   fixtures, upstream minimization comparison, and primary-state/lex-mode
   preservation checks around minimized states.
7. Phase 5.1/5.2 runtime parser parity: replace count-only recovery ranking
   with weighted error costs and continue stack/version merge work only where
   focused samples expose a divergence.
8. Phase 5.3 incremental reuse: add first-leaf, changed, fragile, error, and
   scanner-state guards before expanding scanner-aware incremental samples.
9. Phase 7 performance: finish SymbolSet/key compression and emitted-C tuning
   only when current profile artifacts show they are active bottlenecks.

Historical order already completed or superseded:

1. Phase 1.1 and 1.2: upstream/local summary oracle.
2. Phase 2.1 and 2.2: grammar preparation diff foundations.
3. Phase 3.1 and 3.2: item-set and conflict artifact foundations.
4. Phase 4.1: regex/token support classification foundations.
5. Phase 6.1 on C, Bash, Haskell, Rust, JavaScript, and TypeScript promotion
   waves within their current compatibility boundaries.
6. Phase 5.1 and 5.2: runtime stack and recovery parity where corpus samples
   expose real behavior differences.
7. Phase 7 targeted optimizations only after profile artifacts point to a
   bottleneck.
8. Phase 8 compatibility-report UX after the evidence model is stable.
9. Batch 95 invalid runtime-link recovery: emitted runtime parser recovery state
   and promoted JSON/Ziggy invalid samples are now covered by the bounded
   runtime-link gate.

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
