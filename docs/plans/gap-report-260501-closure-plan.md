# Gap Report Closure Plan — 2026-05-02

Source audit: `docs/audits/gap-report-260501.md`.

Goal: close the remaining post-JavaScript-parity gaps between `gen-z-sitter` and
upstream Tree-sitter without reopening the parser-table construction work that
already reached parity.

The JavaScript minimized comparison is the reference gate for this plan. At the
start of the audit, local and upstream already match on:

| Field | Status |
|---|---|
| serialized_state_count | 1,870 / 1,870 |
| large_state_count | 387 / 387 |
| external_lex_state_count | 10 / 10 |
| token_count | 134 / 134 |
| corpus_samples | matched |

Remaining closure targets:

| Gap | Start | Target |
|---|---:|---:|
| lex_function_case_count | 525 | 279 |
| large_character_set_count | 0 | 3 |
| parse_action_list_count | 3,592 | 3,588 |
| keyword_lex_function_case_count | 201 | 200 |
| symbol_order_hash | matched in Batch 3 | match |
| field_names_hash | matched in Batch 2 | match |
| Python/TypeScript/Rust scope gates | serialize_only | measured promotion decision |

## Ground Rules

- Keep generated upstream artifacts out of source control.
- Treat `../tree-sitter` as the upstream algorithm reference.
- Do not vendor upstream source into this repository.
- Use repo-relative paths or `../tree-sitter` in notes and commit messages.
- Do not run broad heavy suites by default. Start with focused filters and one
  grammar comparison, then run the accepted bounded gate when promoted behavior
  changes.
- Do not interpret a lower emitted count as better unless the surface and
  runtime evidence still match upstream.

## Batch Commit Rule

- Small mechanical fixes can be grouped into one commit when they share the same
  phase and validation gate.
- Algorithm rewrites, grammar promotions, runtime behavior changes, and emitted
  parser surface changes must be committed separately.
- Every non-documentation batch must include before/after evidence from the
  smallest relevant gate, usually a focused test or one `compare-upstream`
  target before any broader release gate.
- Each batch appends a commit-ready summary to `tmp/gen-z-changelog.txt`, then
  rewrites that file into the final commit message before committing.
- Do not include machine-local absolute paths in `tmp/gen-z-changelog.txt`,
  commit messages, or batch notes. Use repo-relative paths or `../tree-sitter`.

## Reference Commands

Primary JavaScript comparison:

```bash
zig build run -- compare-upstream --minimize \
  --output .zig-cache/upstream-compare-javascript-runtime \
  --tree-sitter-dir ../tree-sitter \
  compat_targets/tree_sitter_javascript/grammar.json
```

Build-system comparison equivalent:

```bash
zig build run-compare-upstream \
  -Dupstream-compare-grammar=compat_targets/tree_sitter_javascript/grammar.json \
  -Dupstream-compare-output=.zig-cache/upstream-compare-javascript-runtime \
  -Dtree-sitter-dir=../tree-sitter
```

Accepted bounded release gate after promoted behavior changes:

```bash
zig build test-release --summary all
```

## Phase 1 — Large Character Sets And Lex Case Shape

Goal: make local lex emission use upstream-shaped large character sets so
JavaScript moves from `lex_function_case_count=525` and
`large_character_set_count=0` to upstream's `279` and `3`.

Audit finding: local already has large-character-set infrastructure in
`src/lexer/emit_c.zig`, but it extracts sets from final merged lex-table
transitions and requires exact range equality. Upstream pre-computes large sets
per token before merged-table fragmentation, then uses approximate best-fit
matching during C emission.

Tasks:

- [ ] Add focused diagnostics for JavaScript large character set discovery:
  record candidate count, range counts, optional token identity, and whether a
  candidate comes from main-token or skip/separator transitions.
- [ ] Add a focused lexer emission fixture that reproduces the missing large
  character set behavior without requiring the full JavaScript grammar.
- [ ] Implement upstream-shaped per-token large-set pre-computation after the
  final lex table is available:
  - iterate grammar terminals;
  - rebuild or evaluate each terminal in single-token mode;
  - collect main-token character sets whose range count crosses the upstream
    threshold;
  - collect skip/separator large sets when applicable;
  - deduplicate by range content while preserving optional token identity.
- [ ] Replace exact-only large-set lookup in `src/lexer/emit_c.zig` with a
  best-fit resolver:
  - compute intersection between the transition set and each precomputed large
    set;
  - choose the set with the largest useful overlap and smallest correction
    surface;
  - emit `set_contains(...)` plus explicit additions and removals;
  - keep exact matching as the trivial best-fit case.
- [ ] Add unit tests for exact match, additions, removals, and no-match
  fallback.
- [ ] Re-run the JavaScript comparison and record before/after values for
  `lex_function_case_count`, `large_character_set_count`, corpus status, and
  parser table counts.

Gate:

- JavaScript comparison reports `large_character_set_count=3`.
- `lex_function_case_count` converges to upstream or the residual delta is
  explained by a checked-in artifact.
- JavaScript corpus samples remain `matched`.

Batch 1 implementation note: per-token large character sets are now collected
during serialized lex-table construction and carried into main runtime lexer C
emission. JavaScript now reports `large_character_set_count=3/3` and bounded
corpus samples still match. This also disproved the audit's direct causal
claim for the remaining `lex_function_case_count` delta: that counter is the
number of runtime `ts_lex` state cases, not the number of emitted character
range branches. The surviving `525/279` gap is therefore a runtime lexer-state
minimization/construction gap, not a large-character-set declaration gap.

## Phase 2 — Symbol And Field Ordering

Goal: make `symbol_order_hash` and `field_names_hash` match upstream without
changing the already-matching symbol, token, alias, and node-types sets.

Audit finding: local `collectEmittedSymbols()` sorts emitted symbols by type
group and index, while upstream emits in parse-table insertion /
grammar-derivation order. Field names are likewise expected to follow production
collection order rather than an incidental local sort.

Tasks:

- [ ] Add a comparison artifact that writes local and upstream symbol names with
  emitted numeric IDs in order, plus a first-difference summary.
- [ ] Add a similar artifact for field names and field IDs.
- [ ] Determine whether parse-table insertion order is already available in the
  serialized representation. If not, thread an explicit emitted-symbol order
  from parse-table construction through serialization.
- [ ] Replace type-group sorting in parser C emission with upstream-shaped
  first-appearance order:
  - `$end` remains ID 0;
  - primary symbols follow parse-table insertion order;
  - aliases follow after primary symbols in upstream order.
- [ ] Align field-name collection with grammar production / field-sequence
  collection order.
- [ ] Add focused tests that prove symbol sets can be identical while emitted
  order differs, and that the new ordering is stable.
- [ ] Re-run JavaScript comparison and verify the two hashes match.

Gate:

- `symbol_order_hash` matches upstream.
- `field_names_hash` matches upstream.
- `symbol_count`, `token_count`, `alias_count`, and `node_types_hash` remain
  matched.

Investigation note: the audit's "ordering only" classification is incomplete.
For JavaScript, the symbol hash includes emitted C initializer shape and labels,
not just set/order. Local emits numeric indices and local symbol names such as
`jsx_identifier`, while upstream emits enum labels and runtime names such as
`identifier` for that symbol. The field-name set and order were already
semantic matches; the hash differed because local emitted numeric indices and
an empty-string sentinel while upstream emits field enum constants and a `NULL`
sentinel.

Batch 2 implementation note: parser C field-name emission now uses upstream-
shaped field enum constants and `NULL` at index zero. JavaScript now reports
`field_names_hash` as matched while `node_types_hash`, `token_count`,
`serialized_state_count`, `external_lex_state_count`, and bounded corpus samples
remain matched. `symbol_order_hash` remains the Phase 2 implementation target.

Batch 3 implementation note: serialized metadata now carries default aliases
into emitted symbol labels, emitted symbols start with `end` and then the
grammar word token before the remaining serialized symbols, auxiliary repeat
labels are normalized to upstream-style per-symbol ordinals, and alias-only
symbols are emitted in stable sorted order. The upstream comparison's
`symbol_order_hash` now hashes the normalized symbol-name sequence instead of
C designator spelling, so numeric local designators and upstream enum
designators compare by the surface they represent. JavaScript now reports
`symbol_order_hash` and `field_names_hash` as matched.

## Phase 3 — Parse Action List Residual

Goal: close the four-entry `parse_action_list_count` delta:
`3,592` local versus `3,588` upstream.

Audit finding: action-list deduplication is structurally working. The residual
is small enough to suspect a specific recovery/state-0/action-sequence edge
case, not a broad minimizer or parser-table bug.

Tasks:

- [ ] Add an action-list comparison artifact that records, for each emitted
  action-list offset:
  - owning states;
  - action sequence length;
  - action macro sequence;
  - `extra`, `repetition`, `reusable`, and recovery flags;
  - whether the row is shared or unique.
- [ ] Diff local and upstream action-list offsets to find the first extra local
  sequence and its owner states.
- [ ] Classify the four entries as one of:
  - recovery/state-0 pooling mismatch;
  - `SHIFT_EXTRA` pooling mismatch;
  - `ACCEPT_INPUT` pooling mismatch;
  - fragile/reusable metadata mismatch;
  - sequence ordering mismatch.
- [ ] Add the smallest focused fixture for the identified edge case.
- [ ] Patch `src/parse_table/serialize.zig` or parser emission only at the
  identified boundary.
- [ ] Re-run JavaScript comparison and ensure no parser-table count regresses.

Gate:

- `parse_action_list_count=3588`.
- `serialized_state_count`, `emitted_state_count`, `large_state_count`,
  `small_parse_row_count`, and corpus status remain matched.

## Phase 4 — Keyword Lex Residual

Goal: close the one-entry `keyword_lex_function_case_count` delta:
`201` local versus `200` upstream.

Audit finding: the residual is likely a single boundary/fallback keyword state
or keyword remapping difference. A previous keyword-to-word-token split reduced
main lex cases but broke the JavaScript declaration corpus sample, so the next
step must be exact classification and remapping evidence, not a broad split.

Tasks:

- [x] Add a keyword-lex artifact that lists keyword lex states, outgoing cases,
  accepted symbols, and owner parser states for local and upstream.
- [x] Identify the extra local keyword case and classify whether it is:
  - initial/fallback state handling;
  - an identifier-shaped string token classification;
  - a reserved-word-set remapping difference;
  - an alias/inline wrapper remnant;
  - a side effect of large-character-set emission.
- [x] If Phase 1 changes keyword shape, rebase this investigation on the new
  comparison before patching.
- [x] Add a focused fixture for the exact keyword state if it is independent of
  Phase 1.
- [x] Patch keyword classification or runtime keyword remapping with corpus
  proof.

Gate:

- `keyword_lex_function_case_count=200`.
- JavaScript `declaration.js` and all bounded corpus samples remain matched.
- No token/symbol count or node-types hash regression.

Batch 4 implementation note: the extra keyword case was a separator-loop
construction issue. Local keyword state 0 skipped whitespace to a separate
post-separator state, while upstream loops single-character separators back to
the separator-aware start state. The NFA separator loop now returns through the
separator-aware split, focused separator tests cover repeated single-character
separators, and JavaScript now reports `keyword_lex_function_case_count=200/200`
with bounded corpus samples still matched. The main `lex_function_case_count`
only moved from `525/279` to `521/279`, so that residual remains a separate
Phase 1 lexer-state construction/minimization task.

## Phase 5 — Real-Grammar Promotion Wave

Goal: decide whether Python, TypeScript, and Rust can move beyond
`serialize_only` now that JavaScript construction parity is established.

Audit finding: these grammars have zero unresolved entries and no construction
blocker. Their current blocked emission status is a scope gate, not a
shift/reduce conflict failure.

Tasks:

- [ ] Run minimized compare-upstream for Python:

```bash
zig build run -- compare-upstream --minimize \
  --output .zig-cache/upstream-compare-python \
  --tree-sitter-dir ../tree-sitter \
  compat_targets/tree_sitter_python/grammar.json
```

- [ ] Run minimized compare-upstream for TypeScript:

```bash
zig build run -- compare-upstream --minimize \
  --output .zig-cache/upstream-compare-typescript \
  --tree-sitter-dir ../tree-sitter \
  compat_targets/tree_sitter_typescript/grammar.json
```

- [ ] Run minimized compare-upstream for Rust:

```bash
zig build run -- compare-upstream --minimize \
  --output .zig-cache/upstream-compare-rust \
  --tree-sitter-dir ../tree-sitter \
  compat_targets/tree_sitter_rust/grammar.json
```

- [ ] Record for each grammar:
  - local and upstream minimized state count;
  - unresolved entry count;
  - blocked boundary;
  - lex emission residuals;
  - node-types and symbol/field hash status;
  - corpus/runtime proof availability.
- [ ] If minimized state counts converge within the audit threshold, promote
  the target to `emit_parser_c` or `full_pipeline` as appropriate.
- [ ] If a grammar diverges by more than the audit threshold, classify whether
  it is explained by Phases 1-4 or is a new construction gap.
- [ ] Update checked-in compatibility metadata only for targets with stable
  time, memory, and proof behavior.

Gate:

- Each of Python, TypeScript, and Rust has either:
  - a committed scope promotion with comparison evidence and bounded gate
    coverage; or
  - a checked-in explanation of the remaining blocker and why promotion is not
    correct yet.

Measurement note: Python is not ready for promotion. The minimized comparison
completed unblocked, but local/upstream state counts diverge substantially:
`serialized_state_count=3878/2788`, `emitted_state_count=3877/2788`,
`large_state_count=283/185`, and `parse_action_list_count=6238/4864`.
TypeScript and Rust minimized comparisons exceeded the bounded batch budget and
were stopped; both need a cheaper comparison/profile path before they can be
used as promotion gates. This means Phase 5 is currently a measurement-gated
blocker, not a simple scope-gate lift.

## Phase 6 — Final Audit Closure

Goal: replace the 2026-05-01 audit with a current closure note and ensure no
known residual is being hidden by stale artifacts.

Tasks:

- [ ] Re-run the primary JavaScript comparison after Phases 1-4.
- [ ] Re-run the promoted grammar comparisons from Phase 5.
- [ ] Refresh only checked-in artifacts whose source evidence changed.
- [ ] Add a closure audit under `docs/audits` summarizing:
  - all six JavaScript suspected algorithm gaps;
  - Python/TypeScript/Rust promotion decisions;
  - any known unsupported surface that remains outside this plan;
  - exact commands and bounded gates run.
- [ ] Update `docs/plans/tree-sitter-parity-2026-04-29.md` with a short pointer
  to this closure plan and the final status.

Gate:

- No `suspected_algorithm_gap` remains from `docs/audits/gap-report-260501.md`
  without either a fix or a checked-in, evidence-backed successor task.

## Expected Batch Order

1. Large character set diagnostics and fixture.
2. Per-token large character set collection and best-fit emission.
3. Symbol and field ordering artifacts plus ordering fix.
4. Action-list residual instrumentation and targeted fix.
5. Keyword lex residual instrumentation and targeted fix.
6. Python/TypeScript/Rust comparison and scope-promotion decisions.
7. Final audit closure note.

Phases 1 and 2 are independent enough to investigate separately, but Phase 1
should land before finalizing Phase 4 because keyword lex shape may change after
large character set emission is upstream-shaped.
