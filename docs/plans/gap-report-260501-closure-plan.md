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
| lex_function_case_count | 525 | 279 | 279 | closed |
| large_character_set_count | 0 | 3 | 3 | closed |
| parse_action_list_count | 3,592 | 3,588 | 3,588 | closed |
| keyword_lex_function_case_count | 201 | 200 | 200 | closed |
| symbol_order_hash | mismatch | match | match | closed |
| field_names_hash | mismatch | match | match | closed |
| Python node-types surface | mismatch | match | match | closed |
| Python scope gate | serialize_only | surface matched, parser table divergent | promotion decision | blocked |
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

Batch 8 implementation note: local regex and single-character pattern
one-or-more expansion now follows upstream's completion shape: `+` leaves the
required inner start as the active entry, while `*` is formed by adding the
nullable split around the one-or-more shape. The temporary nullable-start guard
in shared main lexer construction is no longer needed, and the JSON
runtime-link canary no longer loops on zero-width `string_content`. JavaScript
now reports `lex_function_case_count=280/279`, no accepting lex-mode starts,
`serialized_state_count=1870/1870`, `large_state_count=387/387`,
`external_lex_state_count=10/10`, `keyword_lex_function_case_count=200/200`,
and matched bounded corpus samples. This exposed a separate action-list
canonicalization residual: `parse_action_list_count=3568/3588`. A broad
external/internal-token fragility probe was rejected because only
`escape_sequence` moved the metric and it overshot to `3596/3588`; the next
action-list fix must reproduce upstream action-entry construction rather than
add a downstream token-specific pooling heuristic.

Batch 9 implementation note: auxiliary-repeat conflicts are now recognized
before shift/reduce precedence filtering can discard the repeat reduction.
This aligns the JavaScript repeat action surface with upstream:
`REDUCE+SHIFT_REPEAT=83` and `SHIFT_REPEAT=0`, with no repeat singleton owners
and no raw discarded repeat reductions left in the action-list artifact. The
JavaScript comparison moved `parse_action_list_count` from `3568/3588` to
`3572/3588` while preserving `serialized_state_count=1870/1870`,
`large_state_count=387/387`, `external_lex_state_count=10/10`,
`lex_function_case_count=280/279`, and matched bounded corpus samples. A
chosen-candidate canonicalization probe was rejected: dropping diagnostic
candidate actions from chosen rows moved the metric in the wrong direction to
`3534/3588`. The remaining action-list residual is therefore not the repeat
shape; it is in non-repeat conflict/action-entry construction.

Batch 10 lexer-model note: bounded regex repeats now use the same required
prefix plus optional suffix shape as upstream. A focused `{1,3}` regression
test proves that the generated NFA accepts `&a;` and `&abc;` but rejects
`&abcd;`. This is a correctness fix for lexical extraction, but it does not
move the JavaScript parity residuals: the comparison remains at
`parse_action_list_count=3572/3588`, `lex_function_case_count=280/279`,
`large_character_set_count=3/3`, `serialized_state_count=1870/1870`, and
matched bounded corpus samples. A full `{1,30}` recursive matcher test was
rejected as too expensive for the focused gate.

Rejected transition-coalescing probe: upstream's `NfaCursor` coalesces
partitioned transitions with identical target-state sets, separator flags, and
precedence. Applying that shape locally did not reduce
`lex_function_case_count=280/279` and reopened `large_character_set_count` to
`5/3` by exposing extra emitted large-set declarations. Keep the probe as
evidence for the lexer pipeline comparison, but do not land it until the
large-set construction/emission path is aligned with upstream.

Rejected EOF-valid propagation probe: removing EOF validity propagation across
separator transitions fails the focused EOF test. Profiling showed the runtime
shared lexer has four EOF-valid starts, four EOF target states, and one
empty-NFA EOF accept state; the one-case lexer residual is therefore in the
faithful EOF-valid runtime lex construction/minimization shape, not in a
simple missing propagation guard.

Batch 11 construction note: dynamic precedence is now runtime-only conflict
metadata for static shift/reduce resolution, matching upstream's
`build_parse_table` path. This restores the expected JavaScript `pattern`
`REDUCE+SHIFT` rows that local had resolved too early. The state-specific
fragile-token map also now uses upstream's broader `does_overlap` semantics
(`DOES_MATCH_CONTINUATION`, not only valid continuation), so reusable and
non-reusable action entries split the same way as upstream. JavaScript now
matches the full parse-action-list surface:
`parse_action_list_count=3588/3588`, `parse_action_list_entry_count=1794/1794`,
`parse_action_list_flat_width=3738/3738`, `REDUCE+SHIFT=44/44`,
`REDUCE+REDUCE=20/20`, and `REDUCE+REDUCE+SHIFT=2/2`. Parser/table parity is
unchanged: `serialized_state_count=1870/1870`, `large_state_count=387/387`,
`external_lex_state_count=10/10`, `large_character_set_count=3/3`, and
`keyword_lex_function_case_count=200/200`. The only remaining JavaScript audit
residual at that point was `lex_function_case_count=280/279`.

Batch 12 runtime lexer note: the one-case JavaScript `ts_lex` residual was the
pure EOF accept target emitted as a standalone local case. The lexer minimizer
now follows upstream's split-only refinement shape more directly, and C
emission folds a pure end-token accept target into the owning EOF guard when
that state is referenced only by EOF actions and is not a start or transition
target. JavaScript now reports `lex_function_case_count=279/279` while keeping
`serialized_state_count=1870/1870`, `large_state_count=387/387`,
`external_lex_state_count=10/10`, `large_character_set_count=3/3`,
`keyword_lex_function_case_count=200/200`, and
`parse_action_list_count=3588/3588`.

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

Batch 7 implementation note: the JavaScript extras pattern now expands
`\p{Zs}` to the full Unicode separator-space set (`U+0020`, `U+00A0`,
`U+1680`, `U+2000..U+200A`, `U+202F`, `U+205F`, and `U+3000`). This aligns the
recovery whitespace surface with upstream's `extras_character_set_1`, but it
does not by itself move the remaining runtime case count: JavaScript still
reports `lex_function_case_count=281/279`.

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

Current status: closed for the measured JavaScript count. The remaining
action-list shape is not isomorphic to upstream, but the emitted
`parse_action_list_count` gate now matches without a downstream pooling
heuristic.

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

Repeat-pair row diagnostic note: action-list summaries now include
`repeat_pair_rows` for both local serialized/emitted tables and upstream
`parser.c`. The current JavaScript artifact shows local's 22 repeat pairs are
concentrated in string/template/array/object/class-body repeats, while upstream
has 83 pairs dominated by `program_repeat` (43 rows) and `class_body_repeat`
(12 rows). This makes the missing upstream surface explicit without ad hoc
`parser.c` parsing and keeps the rejected broad-preservation result
explainable: forcing the upstream-shaped same-auxiliary predicate converts the
61 singleton rows but overshoots to 85 repeat pairs (`3596/3588`). Relaxing
prefix-only reusable classification independently over-merges to `3568/3588`;
combining both probes over-merges to `3572/3588`. Neither probe is a fix.

Non-repeat conflict-row diagnostic note: action-list summaries now include
`conflict_action_rows` for local/upstream action-list rows and
`conflict_action_owners` for local serialized owner state/symbol entries with
post-filter and raw candidate actions. The current JavaScript artifact shows
local has 80 non-repeat conflict rows while upstream has 66. The shape split is
the important signal: local has 40 `REDUCE+REDUCE`, 38 `REDUCE+SHIFT`, and 2
`REDUCE+REDUCE+SHIFT` rows; upstream has 20 `REDUCE+REDUCE`, 44
`REDUCE+SHIFT`, and 2 `REDUCE+REDUCE+SHIFT` rows. Local owner references are
heavily pooled already: 684 owner entries map onto those 80 rows, with the
largest row (`1180`) referenced by 94 owners. The next action-list fix should
therefore investigate why upstream converts or pools many local `REDUCE+REDUCE`
surfaces into fewer rows, not only why repeat pairs are missing. The fix target
is upstream-faithful action-entry construction/canonicalization before
`ts_parse_actions[]` pooling, not a downstream pooling heuristic that sorts or
hashes already-divergent local rows into the upstream count.

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

Decision-class diagnostic note: local `conflict_action_owners` now records
whether each serialized conflict row came from a chosen decision or an expected
unresolved decision. On the baseline JavaScript artifact, the 80 non-repeat
conflict rows split into 20 chosen `REDUCE+REDUCE` rows, 20 expected
`REDUCE+REDUCE` rows, 38 expected `REDUCE+SHIFT` rows, and 2 expected
`REDUCE+REDUCE+SHIFT` rows. A narrow serializer probe that collapsed the 20
chosen `REDUCE+REDUCE` rows matched upstream's `REDUCE+REDUCE` row count but
over-collapsed the total to `3558/3588` and left local six
`REDUCE+SHIFT` rows short. This disproves row-shape-only chosen conflict
collapse as the final fix.

Rejected fragile-token probe: the two non-reusable local `string_repeat`
repeat-pair rows initially looked like the two-row action-list residual, but
marking `escape_sequence` reusable over-collapsed to `3568/3588` and removed
10 shift rows. Treating all corresponding external/internal tokens the same
also over-collapsed. The remaining action-list fix must preserve upstream's
owner/action-row canonicalization while keeping the current fragile-token
surface, not special-case `escape_sequence` reusable classification.

Batch 7 implementation note: action-list count parity is closed by carrying the
external/internal terminal bitmap into `BuildResult` and using it during
auxiliary-repeat action-entry construction and repetition metadata attachment.
This reproduces the upstream-shaped construction path for corresponding
internal/external repeat tokens before `ts_parse_actions[]` pooling; it does
not add a downstream row-hashing or pooling heuristic. JavaScript now reports
`parse_action_list_count=3588/3588` while preserving
`serialized_state_count=1870/1870`, `large_state_count=387/387`,
`external_lex_state_count=10/10`, and matched bounded corpus samples. The
action-list shape still differs (`SHIFT_REPEAT` singleton rows remain), so
future work should treat count parity as closed but not claim full row-shape
isomorphism.

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

Measurement note: Python is not ready for promotion. After the JavaScript
action-list and runtime lexer residuals closed, the refreshed minimized
comparison still diverges: `symbol_count=275/273`,
`serialized_state_count=2938/2788`, `emitted_state_count=2931/2788`,
`large_state_count=193/185`, `parse_action_list_count=5144/4864`, and
`lex_function_case_count=182/150`. The Python corpus runner now compiles and
bounded external-scanner samples match upstream, so the promotion blocker is no
longer missing runtime proof. The first concrete blocker is surface extraction:
local has extra node types `[^{}\n]+`, `as_pattern_target`, and
`keyword_identifier`. TypeScript and Rust minimized comparisons both exceeded
the bounded batch budget and were stopped; both need a cheaper
comparison/profile path before they can be used as promotion gates. This means
Phase 5 remains a measurement-gated blocker, not a simple scope-gate lift.

Python runtime-link fix note: the corpus runner compile failure was caused by
`ts_supertype_map_slices` being declared with `SYMBOL_COUNT` while local
supertype symbols can be indexed through the alias-tail symbol surface. Parser C
emission now declares that table as `SYMBOL_COUNT + ALIAS_COUNT`; focused
supertype emission tests passed and the Python comparison reports bounded
corpus samples as `matched`.

Python node-types fix note: surface extraction now matches upstream for Python
without reopening the JavaScript reference gate. The fixes are upstream-shaped:
unaliased `token(...)` pattern rules keep their inner pattern source kind, inline
variables are skipped as top-level node types but remain transparent to parents,
aliases of supertypes stay as references instead of materializing alias-only
top-level nodes, inline supertypes remain visible, recursive auxiliary
summaries ignore pure self-recursive alternatives for requiredness, and alias
node merges mark fields/children optional when another alias variant lacks that
surface. The refreshed Python comparison no longer reports `node_types_hash` or
node-type diff mismatches. The remaining Python blockers are parser/table
construction counts: `symbol_count=275/273`, `serialized_state_count=2938/2788`,
`emitted_state_count=2931/2788`, `large_state_count=193/185`,
`parse_action_list_count=5144/4864`, and `lex_function_case_count=182/150`.
The JavaScript reference comparison still reports only the expected
`language_version` difference, with `serialized_state_count=1870/1870`,
`parse_action_list_count=3588/3588`, `lex_function_case_count=279/279`, and
matched bounded corpus samples.

Python symbol-surface fix note: Python now matches upstream on the full emitted
surface before parser-table construction: `symbol_count=273/273`,
`symbol_order_hash=0x1afe251bf085ceb8`, `token_count=108/108`,
`field_names_hash=0xac14787217c045dd`,
`node_types_hash=0xc44a31c1782023ac`, `alias_count=2/2`,
`production_id_count=150/150`, `keyword_lex_function_case_count=162/162`,
`large_character_set_count=2/2`, and `external_lex_state_count=19/19`.
The two fixes were upstream-shaped: parser C emission filters supertype maps to
symbols that are actually emitted instead of adding hidden inline fallback
symbols, and nested unaliased non-string tokens now use upstream-style
`<variable>_token<N>` auxiliary names after lexical-rule deduplication. The
remaining Python blocker is now a parser/table construction gap:
`serialized_state_count=2938/2788`, `emitted_state_count=2931/2788`,
`large_state_count=193/185`, `parse_action_list_count=5144/4864`,
`small_parse_row_count=2738/2603`, and `lex_function_case_count=182/150`.

Python parser/table closure note: the parser/table residual was not a Python
surface problem. Local comparison had been compacting duplicate states by
default, masking the upstream topology, and state-0 recovery lex tokens were
attached after lex-state assignment instead of flowing through the normal
token-set merge path. The upstream-shaped fix disables duplicate-state
compaction in upstream comparisons, computes state-0 recovery tokens before
lex-state assignment, carries the recovery `match_shorter_or_longer` predicate
from the extracted lexer conflict map, and aliases keyword large character sets
to identical main lexer sets during C emission. Python now matches upstream on
all structural fields:
`serialized_state_count=2788/2788`, `emitted_state_count=2788/2788`,
`large_state_count=185/185`, `parse_action_list_count=4864/4864`,
`small_parse_row_count=2603/2603`, `small_parse_map_count=2603/2603`,
`lex_mode_count=2788/2788`, `lex_function_case_count=150/150`,
`keyword_lex_function_case_count=162/162`, `large_character_set_count=2/2`,
and `external_lex_state_count=19/19`; bounded corpus samples and node types
match. JavaScript also remains structurally matched:
`serialized_state_count=1870/1870`, `parse_action_list_count=3588/3588`,
`lex_function_case_count=279/279`, `large_character_set_count=3/3`, and
`external_lex_state_count=10/10`, with bounded corpus samples matched. The only
remaining diff in both summaries is the known local `language_version=15`
versus upstream `14`.

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

Closure note: the original six JavaScript audit gaps are closed:
`large_character_set_count`, `parse_action_list_count`,
`keyword_lex_function_case_count`, `lex_function_case_count`,
`symbol_order_hash`, and `field_names_hash`. JavaScript parser state parity and
bounded corpus equivalence are preserved. The current closure audit records the
non-JavaScript promotion blockers.

Post-memory-fix verification note: after reducing retained parse-table memory in
the local comparison path, the primary JavaScript minimized comparison was rerun
at `tmp/js-post-commit-compare`. The structural baseline remains fully matched:
`symbol_count=261/261`, `token_count=134/134`,
`serialized_state_count=1870/1870`, `emitted_state_count=1870/1870`,
`large_state_count=387/387`, `parse_action_list_count=3588/3588`,
`small_parse_row_count=1483/1483`, `small_parse_map_count=1483/1483`,
`lex_mode_count=1870/1870`, `lex_function_case_count=279/279`,
`keyword_lex_function_case_count=200/200`,
`large_character_set_count=3/3`, and `external_lex_state_count=10/10`.
Bounded corpus samples still match. The only remaining JavaScript summary diff
is the known `language_version=15/14` ABI surface.

Post-Python-conflict verification note: Python was rechecked at
`tmp/python-conflict-variable-index-tight-compare` after aligning local
expected-conflict identity with upstream's item-variable identity. The first
algorithm difference was that local used the inlined production LHS when
constructing recorded conflict members, while upstream uses the parse item's
preserved variable index. With that fixed, Python now matches upstream on the
parser/table surface: `blocked=false/false`, `symbol_count=273/273`,
`token_count=108/108`, `serialized_state_count=2788/2788`,
`emitted_state_count=2788/2788`, `large_state_count=185/185`,
`parse_action_list_count=4864/4864`, `small_parse_row_count=2603/2603`,
`small_parse_map_count=2603/2603`, `lex_mode_count=2788/2788`,
`lex_function_case_count=150/150`, `keyword_lex_function_case_count=162/162`,
`large_character_set_count=2/2`, and `external_lex_state_count=19/19`.
Bounded corpus samples and node types match. The only remaining Python summary
diff is the known local `language_version=15` versus upstream `14` ABI surface.

## Successor Batch Order

1. Keep the Python conflict-identity fix guarded by focused parser-table tests
   and the bounded Python comparison. Reopen only if a later non-bounded corpus
   or emitted artifact shows a concrete regression.
2. Bounded comparison/profile path for TypeScript and Rust.
3. Refresh the closure audit after each promoted non-JavaScript grammar
   decision.

The original large-character-set, symbol/field ordering, and keyword lex tasks
are closed. Do not reopen them unless a new comparison shows a concrete
regression.
