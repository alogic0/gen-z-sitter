# Tree-sitter Parity Plan — 2026-04-29

Goal: move from closing known audit findings to reducing the remaining
implementation gap with upstream Tree-sitter on real grammars, generated C
runtime behavior, external scanners, and bounded corpus evidence.

This plan starts after `docs/plans/audit-findings-plan-2026-04-28.md` was
closed. That plan moved the known 2026-04-28 audit findings into either closed
or measurement-gated status. The next work should therefore begin with a fresh
current-state audit instead of continuing to implement stale items.

## Ground Rules

- Keep generated upstream artifacts out of source control.
- Do not vendor Tree-sitter source files into this project.
- Implement algorithms in Zig and keep the generator self-contained.
- Treat `../tree-sitter` as the algorithm reference checkout.
- Prefer one primary real grammar at a time when debugging algorithm gaps.
- Keep normal test commands bounded; promote a target only when it has stable
  time and memory behavior.
- Record every promoted boundary in checked-in compatibility artifacts.
- Do not convert diagnostic coarse/thresholded modes into correctness claims
  unless the target config explicitly documents why that is acceptable.
- Batch rule: small mechanical fixes can be grouped into one commit when they
  share the same phase and gate. Algorithm rewrites, grammar promotions, and
  runtime behavior changes must be committed separately with before/after
  evidence. Each batch appends a commit-ready summary to
  `tmp/gen-z-changelog.txt`, then rewrites that file into the final commit
  message before committing. Do not run broad heavy suites by default; use
  focused filters first, then the accepted bounded release gate when the batch
  affects promoted behavior. Commit messages and batch notes must use
  repo-relative paths or `../tree-sitter`, not machine-local absolute paths.

## Phase 1 — Fresh Current-State Audit

Goal: replace the now-closed audit plan with a current, accurate implementation
map.

- [x] Re-run the current compatibility report and preserve the refreshed
  checked-in summary only if it changes for a meaningful reason.
- [x] Re-read `docs/audits/gap-report-260428.md` against current code.
- [x] Classify each old finding as closed, superseded, measurement-gated, or
  still active.
- [x] Add a new audit status document under `docs/audits`.
- [x] Update this plan with concrete active gaps discovered by the audit.
- [x] Pick the primary real grammar for the next parity push.

Batch 1 note: `docs/audits/tree-sitter-parity-current-state-2026-04-29.md`
classifies the old 2026-04-28 findings as closed, superseded, or
measurement-gated. No active old-audit findings remain. The current active gaps
are direct parser-table parity for one large real grammar, broader multi-token
scanner proof coverage, generated runtime semantics, curated corpus evidence,
and explicit large-target performance budgets. JavaScript is the primary grammar
for this plan, with Rust as the fallback if JavaScript comparison output is too
broad for the first parser-table fix.

Recommended first primary grammar:

- JavaScript, because it has both parser-only and external-scanner targets in
  the current shortlist, plus multiple accepted and invalid scanner proof
  samples.

Fallback primary grammar:

- Rust, if JavaScript parser-table differences are too broad for the first
  batch. Rust has a smaller scanner promotion surface and a focused raw-string
  invalid proof.

Gate:

- One current audit document names the live gaps, and this plan is updated to
  implement them in order.

## Phase 2 — Parser Table Parity For One Large Grammar

Goal: make the primary real grammar explainable at the parser-table level
before adding broader runtime claims.

Primary grammar: JavaScript

Starting command:

```
zig build run-compare-upstream -Dupstream-compare-grammar=compat_targets/tree_sitter_javascript/grammar.json -Dupstream-compare-output=.zig-cache/upstream-compare-javascript -Dtree-sitter-dir=../tree-sitter
```

Batch order:

- [x] Run the JavaScript local/upstream comparison command and inspect
  `.zig-cache/upstream-compare-javascript/local-upstream-summary.json`.
- [x] Record the first concrete JavaScript parser-table parity gap in this
  plan.
- [x] Add or refine comparison artifacts only if the current summary is too
  coarse to classify the gap.
- [x] Add the smallest focused fixture that reproduces the discovered gap.
- [x] Implement the smallest upstream-aligned fix.
- [x] Re-run the JavaScript comparison and refresh only affected checked-in
  artifacts.

- [x] Run local parser-state, item-set, conflict, minimization, lex-table, and
  parser-C summaries for the primary grammar.
- [x] Run bounded upstream comparison for the same grammar using `../tree-sitter`.
- [x] Identify whether the blocker is grammar preparation, item-set closure,
  conflict resolution, minimization, serialization, lexing, or C emission.
- [x] Add or refine comparison keys where the current artifacts are too coarse.
- [x] Add a focused regression fixture for the smallest discovered algorithm
  difference.
- [x] Implement the first focused upstream-aligned parser-table fixes.
- [x] Replace the partial inline expansion with upstream-style extracted-symbol
  replacement/removal so inlined/tokenized syntax variables do not remain as
  parser variables.
- [x] Carry upstream `ExternalToken.corresponding_internal_token` metadata
  through token extraction and minimization compatibility.
- [ ] Refresh only the affected golden/report artifacts.
- [x] Isolate the remaining compatible-minimizer over-merge, with the first
  suspect being minimizer core identity versus exact upstream item cores.
- [x] Reduce or explain the surviving JavaScript `shift_reduce_expected` rows,
  starting with the `primary_expression` / `lexical_declaration` samples on
  lookahead terminal 41.
- [x] Promote the next state-count mover from symbol/token parity: local
  JavaScript currently exposes 92 lexical tokens versus upstream's 134, so
  some upstream-distinct lookahead rows cannot split local states yet.
- [x] Close JavaScript surface parity before interpreting minimization:
  explain local 92 vs upstream 134 tokens, starting with aliased
  identifier-like tokens that appear in upstream node-types but are missing
  locally (`property_identifier`, `statement_identifier`, and
  `shorthand_property_identifier*`).
- [x] Treat alias/node-type parity as part of the same surface-parity
  workstream as token extraction; use node-types diff as the user-visible proof
  once token identity converges.
- [x] Keep the 1,626 minimized JavaScript count classified as non-actionable
  minimizer-quality evidence until token/symbol extraction, alias/node-types,
  and external scanner valid-symbol rows converge.
- [x] Intern serialized production metadata separately from raw reduce payloads,
  matching upstream's distinction between reduce symbol/child-count/dynamic
  precedence and `production_id` alias/field metadata.
- [x] Close the JavaScript production-info delta: local and upstream now both
  emit 121 production IDs after serialized production metadata and precedence
  resolution were aligned.

Batch 2 note: JavaScript comparison now writes
`.zig-cache/upstream-compare-javascript/local-upstream-summary.json`. Two
comparison infrastructure gaps were fixed first: runtime-only parse-action lists
can now omit unresolved diagnostic candidate rows for bounded comparison and
state compaction, and corpus runner compile failure is recorded in the corpus
section instead of aborting parser-table comparison. The first concrete
JavaScript parser-table gap is conflict/parse-table construction: local
JavaScript is still `blocked=true`, has 11,157 serialized states, and reports
24,976 unresolved decisions; upstream emits an unblocked parser with 1,870
states. The smallest visible surface to reduce next is expected-conflict and
reserved-identifier conflict handling, starting from the unresolved samples in
the generated `local/conflict-summary.json`.

Batch 3 note: two focused parser-table fixes landed locally and pass the fast
unit suite: reserved-word FIRST propagation through nested symbols, and
expected-conflict candidate expansion through auxiliary parent symbols. The
JavaScript comparison showed that these are correct local pieces but not enough
to unblock JavaScript. A bounded token-like inline expansion then moved the
first visible conflict sample from `_reserved_identifier` to `primary_expression`,
which confirms that inline declarations are part of the active gap, but the
partial implementation is not a valid promotion boundary: JavaScript grew from
11,157 to 12,618 states and from 24,976 to 31,339 unresolved decisions. The next
required parser-table step is not broader conflict resolution; it is
upstream-style symbol replacement/removal during token extraction/inlining, so
extracted inline variables like `_reserved_identifier`, `_identifier`, and
`_semicolon` do not remain as independent parser variables.

Batch 4 note: the next root-cause pass checked upstream
`prepare_grammar/process_inlines.rs` and `build_tables/item_set_builder.rs`.
The important upstream behavior is not global grammar rewriting. Tree-sitter
keeps `variables_to_inline` in the syntax grammar, builds an
`InlinedProductionMap` keyed by `(production, step_index)`, and substitutes those
productions lazily when item-set closure reaches an inline step. Two local
experiments were rejected: global collect-time inline expansion timed out the
bounded JavaScript comparison, and leaf-only/token-choice lazy substitution
completed but worsened JavaScript to 12,620 states and 49,988 unresolved
decisions because wrappers like `_identifier` still reduced through
`_reserved_identifier`. Broad nested lazy substitution exposed a separate
reduce/reduce issue in the inline field-inheritance fixture. The next
implementation should therefore reproduce the upstream inlined-production map
more faithfully, including substituted production identity and hidden-field
inheritance, before promoting another JavaScript comparison boundary.

Batch 5 note: the upstream-style `InlinedProductionMap` is now built lazily
during item-set closure, and inline cursor symbols are guarded before successor
grouping so parser states no longer transition on inline variables. That moved
JavaScript from the earlier blocked parser-table construction to an unblocked
comparison, but exact parity is still not reached. Without minimization the
local JavaScript table reports 2,777 states versus upstream's 1,870; with the
compatible minimizer enabled, local JavaScript over-merges to 1,626 states
versus upstream's 1,870, with 14 unresolved expected-conflict entries remaining.
The next concrete parity task is upstream's corresponding-internal external
token rule: external tokens that also correspond to an internal terminal must be
recorded during extraction and must block otherwise-compatible minimizer merges,
matching `../tree-sitter`'s minimization constraints.

Batch 6 note: corresponding-internal external token metadata now flows through
token extraction into the minimizer conflict map. The focused fixture covers the
JavaScript-shaped duplicate literal case where an external string rule matches
an already extracted anonymous terminal. JavaScript comparison confirms the
external `'||'` token is now recorded as the internal terminal name, and the
minimized table remains unblocked, but this does not change the remaining
state-count gap: local JavaScript is still 1,626 minimized states versus
upstream's 1,870. The next task is therefore not external-token metadata; it is
the compatible-minimizer over-merge itself, starting with whether local
structural item identity is making minimizer core groups broader than upstream's
exact parse item cores.

Batch 7 note: two minimizer over-merge suspects have now been ruled out by
bounded JavaScript probes. First, grouping minimizer inputs by exact
`(production_id, step_index)` item cores instead of local structural core ids
left JavaScript at 1,626 minimized states, so structural item identity is not
the active over-merge cause. Second, upstream's `is_repetition` shift metadata
is now carried into resolved action groups and used as a minimizer split
condition, with a focused regression test, but JavaScript still reports 1,626
minimized states. Rejected probes also showed that splitting on reserved-word
set id contradicts the existing reserved-word merge fixture, broad
starting-overlap token conflicts prevent JavaScript minimization entirely, and
all-token follow sets only move JavaScript from 1,626 to 1,628 states. The
remaining concrete surface is the 14 default / 7 minimized
`shift_reduce_expected` rows, especially the repeated
`primary_expression`/`lexical_declaration` samples, rather than a generic
minimizer grouping condition.

Batch 8 note: the `primary_expression`/`lexical_declaration` samples were
reduced enough to rule out the stale inline-cursor explanation: both the current
and prior JavaScript artifacts have zero finalized items whose cursor is on one
of JavaScript's inline variables. The visible lookahead terminal 41 is `[`, and
the extra `lexical_declaration` member comes from declaration items whose next
symbol can begin with an array pattern. One small upstream minimizer mismatch
was fixed: keyword-token classification now follows upstream's one-way
`does_match_same_string && !does_match_different_string` rule instead of local's
broader symmetric same-string check, with a focused parser-table regression.
The bounded JavaScript comparison still reports 1,626 minimized states, 14
default unresolved expected-conflict rows, and 7 minimized unresolved
expected-conflict rows. The next state-count mover is therefore likely earlier
symbol/token parity, not another generic compatible-minimizer split: local
JavaScript exposes 92 lexical tokens while upstream exposes 134.

Surface-parity rule: do not interpret JavaScript's 1,626 minimized local states
as a minimizer quality signal until the generated surface converges. The active
workstream is token/symbol extraction and aliases together: local's 92 lexical
tokens versus upstream's 134 means local is missing upstream-distinct lookahead
rows, and the missing node-types entries (`property_identifier`,
`statement_identifier`, `shorthand_property_identifier`, and
`shorthand_property_identifier_pattern`) are proof that alias promotion and
token extraction are still coupled. External scanner valid-symbol rows remain a
separate surface gate before minimized table counts become meaningful.

Batch 9 investigation note: the 92-token surface is not the raw lexical
extraction count. The current JavaScript artifact has 130 extracted lexical
variables, but parser emission serializes only 92 token/external symbols because
`collectEmittedSymbols` only discovers referenced symbols and synthetic terminal
metadata falls back to `terminal:N` labels. Upstream's extraction does an
additional symbol-replacement pass: if a syntax variable's entire rule was
extracted into a uniquely-used terminal, it removes that syntax variable,
renames/kinds the lexical variable with the syntax variable metadata, and remaps
all later symbols. Local still keeps wrappers like `hash_bang_line`,
`jsx_identifier`, string-fragment rules, `escape_sequence`, `regex_pattern`,
`number`, `identifier`, and `private_property_identifier` as syntax variables
while also extracting matching lexical variables. The alias side is similarly
coupled: local `parser.c` already contains alias symbols for
`property_identifier`, `shorthand_property_identifier`,
`shorthand_property_identifier_pattern`, and `statement_identifier`, but
node-types generation does not enumerate named production aliases through an
upstream-style aliases-by-symbol map. The next implementation step is therefore
the upstream `SymbolReplacer`-shaped extraction/remap pass, with node-types
alias enumeration used as a visible proof surface.

Batch 10 note: the JavaScript surface-parity gate is now mostly closed. The
bounded upstream comparison reports matching symbol count (261), token count
(134), external token count (8), alias count (4), and node-types hash
(`0xd9183da56f875d8c`). A focused precedence fix reduced unresolved expected
conflicts to 5 non-blocking `shift_reduce_expected` rows. Serialized production
metadata now follows upstream's two-part model: reduce actions keep their raw
symbol/child-count/dynamic-precedence payload while `production_id` indexes
interned alias/field metadata. That moved JavaScript `PRODUCTION_ID_COUNT` from
1260 to 135. The remaining production-info delta is precise rather than broad:
upstream has 121 production IDs, and local's metadata set is an upstream
superset with 14 local-only rows. The next task is to decide whether those rows
come from default-alias clearing, context-inherited inline fields, or local-only
inline productions before touching state minimization again.

Batch 11 note: the JavaScript parser-table gate is now closed on the structural
surface that blocked Phase 2. The precedence-order comparison was inverted
locally; fixing it moved minimized JavaScript from the 2,161/2,171 plateau to
1,869 states. The remaining one-state delta was not a minimizer logic bug:
`../tree-sitter` reserves parse state 0 as the error/recovery state and starts
the real grammar at state 1. Local construction now does the same, and
serialization populates state 0 with upstream-shaped `RECOVER` entries before
external scanner state assignment. The final minimized comparison
`.zig-cache/upstream-compare-javascript-final-mile/local-upstream-summary.json`
reports local/upstream parity for the active parser-table blockers:
`blocked=false`, `symbol_count=261`, `token_count=134`, `alias_count=4`,
`node_types_hash=0xd9183da56f875d8c`, `production_id_count=121`,
`serialized_state_count=1870`, `emitted_state_count=1870`,
`lex_mode_count=1870`, and `external_lex_state_count=10`. Remaining JavaScript
diffs are emission-shape and lexer-emission metrics (`large_state_count`,
parse-action list/small-table packing, lex function case counts, keyword lex
table shape, and large character sets), not the conflict/parse-table
construction blocker.

Batch 12 note: the first post-Phase-2 runtime and emission-shape pass closed
three follow-up gaps. JavaScript comparison now links the real external scanner
from `compat_targets/tree_sitter_javascript_scanner_json/runtime_proof_config.json`
instead of reporting `runner_compile_failed`, and generated local `parser.c`
uses runtime lexer tables with EOF-valid lex states. A compaction bug that
dropped serialized `recover` flags was fixed, so state 0 emits `RECOVER()`
instead of aliasing the accept action. The bounded comparison now reports
`corpus_samples.status="matched"` for five JavaScript samples, including the
multi-token accepted sample
`compat_targets/tree_sitter_javascript_scanner/declaration.js`. Emission-shape
parity also moved: `large_state_count`, `small_parse_row_count`, and
`small_parse_map_count` now match upstream (`387`, `1483`, and `1483`). The
remaining JavaScript emission diffs are parse-action list shape/count and lexer
emission shape (`lex_function_case_count`, `keyword_lex_function_case_count`,
and large character sets), plus the known language-version and ordering hashes.

Gate:

- The primary grammar has either advanced one parser-table boundary or has a
  precise checked-in explanation of the next unresolved algorithm gap.

## Phase 3 — External Scanner Runtime Expansion

Goal: move from single-token scanner proofs toward realistic multi-token
scanner behavior without making routine tests heavy.

- [x] For the primary grammar, add one multi-token accepted scanner sample.
- [x] Add runtime proof config metadata for the sample file and proof id.
- [x] Assert generated parser metrics where stable: consumed bytes, error
  count, error cost, and dynamic precedence.
- [ ] Add scanner serialize/deserialize checks if the scanner state changes
  across the sample.
- [x] Add one invalid scanner sample only after the accepted path is stable.
- [x] Keep target runtime under the accepted bounded-suite cost.

Gate:

- One real scanner target proves more than an isolated external token and still
  passes through the generic runtime proof config path.

## Phase 4 — Generated Runtime Semantics

Goal: reduce behavioral differences between the generated parser runtime and
upstream parser behavior.

- [ ] Audit generated GLR version merge behavior against upstream stack
  semantics for the primary grammar sample.
- [ ] Add focused runtime-link tests for scanner-state preservation across
  multiple parse versions.
- [x] Add focused invalid-input tests for recovery tree shape where the current
  temporary API exposes enough information.
- [ ] Add incremental parsing samples for the primary grammar when scanner
  state is involved.
- [ ] Record remaining temporary API limits explicitly instead of hiding them
  in test names.

Gate:

- Runtime-link tests cover at least one accepted, one invalid, and one
  scanner-state-sensitive path for the primary grammar or a reduced fixture
  derived from it.

## Phase 5 — Bounded Corpus Compatibility

Goal: start proving real grammar behavior on curated corpus samples without
running the full upstream corpus.

- [x] Add a bounded corpus runner for one grammar.
- [x] Start with three curated samples: smallest accepted, scanner accepted,
  and invalid/recovery.
- [x] Compare accepted/error status and root tree string where stable.
- [x] Record divergences as structured artifacts with sample labels and
  mismatch categories.
- [x] Keep corpus execution out of fast unit tests unless the samples are very
  small.

Gate:

- One real grammar has checked-in curated corpus evidence that can be rerun
  without hanging or exhausting memory.

## Phase 6 — Performance And Bounds

Goal: keep larger grammar work usable on a development machine.

- [ ] Add or confirm per-target wall-clock and memory budgets for promoted
  compatibility steps.
- [ ] Add stage-level timing where a promoted target approaches its budget.
- [ ] Profile only the slowest current stage for a target.
- [ ] Avoid structural performance rewrites until measurements identify the
  dominant cost.
- [ ] Document intentionally heavy tests and keep them outside routine test
  commands.

Gate:

- Promoted compatibility work remains bounded, and any expensive target has a
  clear diagnostic command rather than being part of normal unit tests.

## Phase 7 — Release Boundary Update

Goal: align documentation with the implementation evidence after the parity
work advances.

- [ ] Update the release boundary inventory after the primary grammar moves.
- [ ] Update README and HOWTO wording for supported grammar classes.
- [ ] Document which generated parser surfaces are stable and which remain
  temporary.
- [ ] Document what users can rely on for parser-only grammars, external
  scanner grammars, generated C output, and highlighter use cases.
- [ ] Add a short "known limits" section pointing to current audit/status docs.

Gate:

- User-facing docs match the compatibility evidence rather than the intended
  future state.

## Implementation Order

1. Phase 1: create the fresh audit and choose the primary grammar.
2. Phase 2: reduce or precisely classify the primary parser-table gap.
3. Phase 3: expand scanner runtime proof coverage for the same grammar.
4. Phase 4: tighten generated runtime semantics around the discovered samples.
5. Phase 5: add bounded curated corpus evidence.
6. Phase 6: enforce performance bounds as soon as a promoted target becomes
   expensive.
7. Phase 7: update user-facing release and usage documentation after evidence
   changes.

Do not start broad corpus work until the primary grammar's parser-table and
scanner-runtime boundaries are clear enough to debug failures without guessing.
