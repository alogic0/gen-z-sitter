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

Current closure status:

| Gap | Start | Current | Target | Status |
|---|---:|---:|---:|---|
| lex_function_case_count | 525 | 281 | 279 | successor task; local too high by 2 |
| large_character_set_count | 0 | 3 | 3 | closed |
| parse_action_list_count | 3,592 | 3,592 | 3,588 | successor task |
| keyword_lex_function_case_count | 201 | 200 | 200 | closed |
| symbol_order_hash | mismatch | match | match | closed |
| field_names_hash | mismatch | match | match | closed |
| Python scope gate | serialize_only | measured, not promotable | promotion decision | blocked |
| TypeScript/Rust scope gates | serialize_only | timed out in bounded compare | promotion decision | measurement-gated |

Closure audit: `docs/audits/gap-report-260501-closure-2026-05-02.md`.

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
- Treat every residual direction change as a new diagnostic. The main lexer
  residual has moved from local-too-low to local-too-high; do not continue
  debugging it as an over-merge without re-checking the current comparison.

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

- [x] Add focused diagnostics for JavaScript large character set discovery:
  record candidate count, range counts, optional token identity, and whether a
  candidate comes from main-token or skip/separator transitions.
- [x] Add a focused lexer emission fixture that reproduces the missing large
  character set behavior without requiring the full JavaScript grammar.
- [x] Implement upstream-shaped per-token large-set pre-computation after the
  final lex table is available:
  - iterate grammar terminals;
  - rebuild or evaluate each terminal in single-token mode;
  - collect main-token character sets whose range count crosses the upstream
    threshold;
  - collect skip/separator large sets when applicable;
  - deduplicate by range content while preserving optional token identity.
- [x] Replace exact-only large-set lookup in `src/lexer/emit_c.zig` with a
  best-fit resolver:
  - compute intersection between the transition set and each precomputed large
    set;
  - choose the set with the largest useful overlap and smallest correction
    surface;
  - emit `set_contains(...)` plus explicit additions and removals;
  - keep exact matching as the trivial best-fit case.
- [x] Add unit tests for exact match, additions, removals, and no-match
  fallback.
- [x] Re-run the JavaScript comparison and record before/after values for
  `lex_function_case_count`, `large_character_set_count`, corpus status, and
  parser table counts.

Gate:

- JavaScript comparison reports `large_character_set_count=3`.
- `lex_function_case_count` converges to upstream or the residual delta is
  explained by a checked-in artifact. Track the direction explicitly: the
  current residual is local too high (`281/279`), so the next diagnosis is the
  two extra runtime DFA cases that remain after lex-mode start parity, not the
  earlier broad over-merge.
- JavaScript corpus samples remain `matched`.

Batch 1 implementation note: per-token large character sets are now collected
during serialized lex-table construction and carried into main runtime lexer C
emission. JavaScript now reports `large_character_set_count=3/3` and bounded
corpus samples still match. This also disproved the audit's direct causal
claim for the remaining `lex_function_case_count` delta: that counter is the
number of runtime `ts_lex` state cases, not the number of emitted character
range branches. The surviving `525/279` gap is therefore a runtime lexer-state
minimization/construction gap, not a large-character-set declaration gap.

Batch 5 implementation note: main lex-table construction now follows upstream's
keyword-capture shape by replacing identifier-shaped keyword terminals with the
grammar word token before building runtime lex tables. Runtime lex minimization
also preserves distinct lex-mode start rows instead of merging them with
ordinary successor states. JavaScript main `lex_function_case_count` moved from
`521/279` to `266/279`, with `keyword_lex_function_case_count=200/200`,
`large_character_set_count=3/3`, and bounded corpus samples still matched. The
residual direction has flipped from local over-emission to local under-emission:
local is now lower than upstream (`266/279`). The remaining delta is therefore a
narrower local runtime-lex over-merge/minimization difference: local emits 10
unique lex mode start states while upstream emits 16, and preserving start rows
accounts for 2 of the 15 previously over-merged runtime cases.

Batch 6 implementation note: state-0 recovery lex-state attachment and runtime
lexer minimizer alignment moved the JavaScript main lexer residual from local
too low to local too high. The current comparison reports
`lex_function_case_count=281/279`, `lex_mode_count=1870/1870`, and 16 unique
lex-mode starts on both local and upstream. The remaining lexer gap is now two
reachable runtime DFA cases, not missing start-row separation. Two focused
experiments were rejected: ignoring EOF-target presence in the runtime lexer
initial signature did not move the count, and a canonical fixed-point runtime
partitioning pass also left `281/279` unchanged.

Immediate lexer diagnostic: the current state-0 `ts_lex` body is structurally
different from upstream even though the state and lex-mode counts now match.
Local emits explicit skip/identifier ranges in case 0, including space, `_`,
NBSP, zero-width, word-joiner, and BOM branches, while upstream uses
`extras_character_set_1` plus a broad identifier transition from the recovery
entry. The next lexer batch should diff local/upstream runtime DFA cases by
start-mode owner and transition set, starting with state 0 and the two extra
reachable local cases. This is a state-0 recovery lex-table shape issue until
proven otherwise, not a lex-mode start-count issue.

Rejected NFA diagnostic: local regex one-or-more expansion appears to permit an
invalid zero-repeat path in isolated token-sequence inspection, but the focused
fix worsened JavaScript action-list parity (`3568/3588`) and did not move the
main lexer case count (`281/279`). Keep this as a separate lexer-model
correctness investigation, not as the current JavaScript parity fix.

Rejected runtime-lexer construction diagnostic: rebuilding JavaScript's runtime
lexer through one shared multi-start DFA builder, matching upstream's broad
construction shape more closely than the local per-lex-mode table stitching,
did not move the residual. JavaScript remained at `lex_function_case_count=281/279`,
`parse_action_list_count=3592/3588`, parser-table counts matched, and corpus
samples matched. The two-case lexer residual is therefore not explained by the
per-table-versus-shared-table construction boundary.

Rejected recovery-isolation diagnostic: allowing runtime lexer state 0 to share
the ordinary initial-signature path also did not move JavaScript
(`281/279`). The residual is not caused by the current error-state-only
partition barrier in runtime lex minimization.

Gate-fix note: the keyword-capture split exposed a runtime-link regression for
word-token grammars that have identifier-shaped string keywords but no reserved
word sets. Local skipped keyword-table emission in that case, so samples such as
Ziggy schema `root = bytes` and the Zig accepted runtime-link sample could lex
keyword-shaped strings as the word token rather than the literal keyword.
Keyword lex tables are now emitted whenever a word token exists and
keyword-shaped string terminals are present. At that point the JavaScript
comparison remained unchanged (`266/279`, `200/200`, `3/3`, corpus matched);
the later state-0/runtime lexer batch moved the main lexer residual to
`281/279`. The keyword and large-character-set gates remain closed, and
`zig build test-release --summary all` passed. There is no intentionally open
Zig word-token runtime-link failure in this plan; if that gate regresses, stop
before action-list work and fix the runtime boundary first.

## Phase 2 — Symbol And Field Ordering

Goal: make `symbol_order_hash` and `field_names_hash` match upstream without
changing the already-matching symbol, token, alias, and node-types sets.

Audit finding: local `collectEmittedSymbols()` sorts emitted symbols by type
group and index, while upstream emits in parse-table insertion /
grammar-derivation order. Field names are likewise expected to follow production
collection order rather than an incidental local sort.

Tasks:

- [x] Add a comparison artifact that writes local and upstream symbol names with
  emitted numeric IDs in order, plus a first-difference summary.
- [x] Add a similar artifact for field names and field IDs.
- [x] Determine whether parse-table insertion order is already available in the
  serialized representation. If not, thread an explicit emitted-symbol order
  from parse-table construction through serialization.
- [x] Replace type-group sorting in parser C emission with upstream-shaped
  first-appearance order:
  - `$end` remains ID 0;
  - primary symbols follow parse-table insertion order;
  - aliases follow after primary symbols in upstream order.
- [x] Align field-name collection with grammar production / field-sequence
  collection order.
- [x] Add focused tests that prove symbol sets can be identical while emitted
  order differs, and that the new ordering is stable.
- [x] Re-run JavaScript comparison and verify the two hashes match.

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

- [x] Before adding action-list instrumentation, rerun
  `zig build test-release --summary all` and confirm the Ziggy schema and Zig
  word-token runtime-link accepted samples still pass. Do not update action-list
  goldens or diagnostics on top of a broken release gate.
- [x] Diff local and upstream action-list offsets to find the first extra local
  sequence and its owner states.
- [x] Classify the four entries.

Gate:

- `parse_action_list_count=3588`.
- `serialized_state_count`, `emitted_state_count`, `large_state_count`,
  `small_parse_row_count`, and corpus status remain matched.

Investigation note: `zig build test-release --summary all` passes `1520/1520`
(release gate clean). Direct comparison of the emitted action lists (JavaScript
`--minimize` comparison artifacts) shows a broader action-shape mismatch than
the four-entry counter suggests. Local currently has 61 `SHIFT_REPEAT`
singleton rows and 22 `REDUCE + SHIFT_REPEAT` rows, while upstream has zero
`SHIFT_REPEAT` singletons and 83 `REDUCE + SHIFT_REPEAT` rows. This confirms
that auxiliary-repeat action shape differs substantially at emission time.

A broad resolver change that preserved all repeat-auxiliary reductions moved
the metric the wrong way (`3596/3588`), so the fix is not simply "keep every
repeat reduce." The next action-list batch needs narrower owner-state
instrumentation: for each local `SHIFT_REPEAT` singleton, record the owning
state/symbol, the pre-filter candidate actions, whether the discarded reduction
belongs to the same auxiliary repeat, and the corresponding upstream row shape.
Only then adjust the resolver or serializer for the exact repeat class upstream
keeps paired.

Current status: partially classified, deferred. This plan's Phase 3 gate
(`3588`) remains unmet; broad repeat-preservation was disproved as a fix.

Action-list instrumentation note: `compare-upstream` now writes
`local/action-list-summary.json`. The minimized JavaScript artifact confirms
the emitted local action-list shape still has 61 unique `SHIFT_REPEAT`
singleton rows and 22 `REDUCE+SHIFT_REPEAT` rows. It also records 80 owner
state/symbol entries whose raw minimized action group contained a shift plus a
repeat-auxiliary reduce, but whose post-filter serialized entry retained only
the repeated shift. The dominant class is state 62 reducing production 587
(`program_repeat142 -> program_repeat142 program_repeat142`) across 55
statement-start symbols. This narrows the next fix to the exact repeat
reduction filtering/serialization class; do not retry the already-rejected
"preserve every repeat reduce" change.

Successor diagnostic note: `compare-upstream` now also writes
`upstream/action-list-summary.json` so the upstream `ts_parse_actions[]` shape
is available beside the local owner-level artifact. Current upstream shape is
1,794 rows, 3,588 initializer braces, 3,738 flat entries, zero
`SHIFT_REPEAT` singleton rows, and 83 `REDUCE+SHIFT_REPEAT` rows. Current local
shape is 1,796 rows, 3,592 initializer braces, 3,695 flat entries, 61
`SHIFT_REPEAT` singleton rows, and 22 `REDUCE+SHIFT_REPEAT` rows.

Rejected minimizer diagnostic: merging duplicate resolved action groups during
state minimization can force the brace counter to `3588`, but the broad version
turns the grammar `blocked=true` by creating blocking merged decisions, and the
narrow auxiliary-repeat-only version keeps `blocked=false` while overshooting to
`3652/3588`. The action-list residual therefore should not be fixed by
unioning duplicate action groups in the minimizer. The next attempt should use
the paired local/upstream action-list artifacts to identify whether the two-row
residual comes from reusable classification, repeat conflict preservation at
construction time, or runtime action-list pooling after parse-table emission.

Rejected construction fallback diagnostic: removing the
`productionIsRepeatAuxiliary` shift preference in `resolveShiftReduce` breaks
the focused repeat-resolution fixture and leaves JavaScript unchanged at
`parse_action_list_count=3592/3588`. The JavaScript repeat-singleton residual is
therefore not caused by that fallback alone.

Batch diagnostic fix: local small-parse-table action lookup had a singleton
fast path that ignored the `reusable` bit, so reusable terminal entries could
reference a non-reusable singleton action row when both rows had the same
runtime action. That left 163 local `ts_parse_actions[]` rows unreferenced,
while upstream only leaves row 0 unreferenced. The lookup now indexes only
reusable singleton rows for reusable fast-path use; JavaScript still reports
`parse_action_list_count=3592/3588`, but local and upstream now both have only
row 0 unreferenced. `zig build test-release --summary all` passed.

Successor owner finding: parsing upstream `parser.c` owner references confirms
that upstream keeps JavaScript's `program_repeat` conflict as
`REDUCE + SHIFT_REPEAT` rows where local emits `SHIFT_REPEAT` singleton rows.
The local singleton action index `583` is reused by three different discarded
repeat reductions (`587`, `589`, and `644`) for the `@` token; this explains why
the broad serialization-side reconstruction produced `85` repeat pairs and
overshot to `3596/3588` instead of upstream's `83` repeat pairs. The next
action-list patch must not reconstruct repeat reductions per owner blindly; it
needs the same owner/action-row canonicalization that upstream applies before
parse-action-list pooling.

Rejected repeat-metadata downgrade: limiting repetition metadata to entries
that still carry multiple candidate actions removed all 61 local
`SHIFT_REPEAT` singleton rows, but it collapsed JavaScript action-list parity
too far (`3470/3588`) while leaving the lexer residual unchanged (`281/279`).
This confirms the singleton repeat rows are carrying real pooling structure;
the fix is to preserve the missing `REDUCE + SHIFT_REPEAT` conflict surface,
not to downgrade singleton repeat shifts to ordinary `SHIFT` rows.

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

- [x] Run minimized compare-upstream for Python:

```bash
zig build run -- compare-upstream --minimize \
  --output .zig-cache/upstream-compare-python \
  --tree-sitter-dir ../tree-sitter \
  compat_targets/tree_sitter_python/grammar.json
```

- [x] Attempt minimized compare-upstream for TypeScript within the bounded
  batch budget:

```bash
zig build run -- compare-upstream --minimize \
  --output .zig-cache/upstream-compare-typescript \
  --tree-sitter-dir ../tree-sitter \
  compat_targets/tree_sitter_typescript/grammar.json
```

- [x] Attempt minimized compare-upstream for Rust within the bounded batch
  budget:

```bash
zig build run -- compare-upstream --minimize \
  --output .zig-cache/upstream-compare-rust \
  --tree-sitter-dir ../tree-sitter \
  compat_targets/tree_sitter_rust/grammar.json
```

- [x] Record for each grammar:
  - local and upstream minimized state count;
  - unresolved entry count;
  - blocked boundary;
  - lex emission residuals;
  - node-types and symbol/field hash status;
  - corpus/runtime proof availability.
- [x] If minimized state counts converge within the audit threshold, promote
  the target to `emit_parser_c` or `full_pipeline` as appropriate.
- [x] If a grammar diverges by more than the audit threshold, classify whether
  it is explained by Phases 1-4 or is a new construction gap.
- [x] Update checked-in compatibility metadata only for targets with stable
  time, memory, and proof behavior.

Gate:

- Each of Python, TypeScript, and Rust has either:
  - a committed scope promotion with comparison evidence and bounded gate
    coverage; or
  - a checked-in explanation of the remaining blocker and why promotion is not
    correct yet.

Measurement note: Python is not ready for promotion. The minimized comparison
completed unblocked, but local/upstream state and surface counts still diverge:
`symbol_count=275/273`, `serialized_state_count=2812/2788`,
`emitted_state_count=2811/2788`, `large_state_count=193/185`,
`parse_action_list_count=4900/4864`, and `lex_function_case_count=128/150`.
That Python lex case direction matched the earlier JavaScript `266/279`
measurement, but no longer matches the current JavaScript `281/279` residual.
Re-run Python after the JavaScript lexer residual is closed before treating it
as the same defect class. The Python corpus runner also failed to compile, so
there is no runtime proof for promotion. TypeScript and Rust minimized comparisons both
exceeded the bounded batch budget and were stopped; both need a cheaper
comparison/profile path before they can be used as promotion gates. This means
Phase 5 is currently a measurement-gated blocker, not a simple scope-gate lift.

No compatibility metadata was promoted in this phase because none of the three
targets met the stability and proof requirements.

## Phase 6 — Final Audit Closure

Goal: replace the 2026-05-01 audit with a current closure note and ensure no
known residual is being hidden by stale artifacts.

Tasks:

- [x] Re-run the primary JavaScript comparison after Phases 1-4.
- [x] Re-run the promoted grammar comparisons from Phase 5.
- [x] Refresh only checked-in artifacts whose source evidence changed.
- [x] Add a closure audit under `docs/audits` summarizing:
  - all six JavaScript suspected algorithm gaps;
  - Python/TypeScript/Rust promotion decisions;
  - any known unsupported surface that remains outside this plan;
  - exact commands and bounded gates run.
- [x] Update `docs/plans/tree-sitter-parity-2026-04-29.md` with a short pointer
  to this closure plan and the final status.

Gate:

- No `suspected_algorithm_gap` remains from `docs/audits/gap-report-260501.md`
  without either a fix or a checked-in, evidence-backed successor task.

Closure note: the original six JavaScript audit gaps are no longer all active
algorithm gaps. Four are closed (`large_character_set_count`,
`keyword_lex_function_case_count`, `symbol_order_hash`, and
`field_names_hash`). Two remain as evidence-backed successor tasks:
`parse_action_list_count=3592/3588` and `lex_function_case_count=281/279`.
Both preserve JavaScript parser state parity and bounded corpus equivalence.
The current closure audit records the exact residuals and promotion blockers.

## Successor Batch Order

1. Action-list residual instrumentation and targeted fix for
   `parse_action_list_count=3592/3588`.
2. Runtime lex minimization diagnostics and targeted fix for the current
   JavaScript two-case excess: `lex_function_case_count=281/279`. Start with
   state-0 runtime DFA shape: local emits explicit recovery whitespace and
   identifier ranges where upstream routes through an extras set and broad
   identifier transition. Re-check Python before using it as a same-class
   signal, because JavaScript's residual direction has flipped since the
   earlier Python measurement.
3. Bounded comparison/profile path for TypeScript and Rust.
4. Python promotion blocker investigation, starting with `symbol_count=275/273`
   and corpus runner compilation.
5. Refresh the closure audit after either JavaScript residual closes.

The original large-character-set, symbol/field ordering, and keyword lex tasks
are closed. Do not reopen them unless a new comparison shows a concrete
regression.
