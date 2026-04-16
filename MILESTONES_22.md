# MILESTONES 22 (Parser-Only Compatibility Coverage)

This milestone turns the `parser-only repo cases first` decision from [MILESTONES_21.md](./MILESTONES_21.md) into a concrete execution plan.

Its purpose is to move the project from curated local fixture proof toward real grammar/repo compatibility proof, while staying inside the current scanner-free boundary. The goal is not “cover every Tree-sitter grammar.” The goal is to establish a repeatable parser-only compatibility harness that can measure real generated-parser usefulness on a small, credible repo set.

This milestone starts from the current boundary already established by:

- `src/parse_table/pipeline.zig`
- `src/parser_emit/parser_c.zig`
- `src/parser_emit/parser_tables.zig`
- `src/parser_emit/c_tables.zig`
- `src/parser_emit/compat_checks.zig`
- `src/behavioral/harness.zig`
- `src/cli/command_generate.zig`

It does not assume broader lexer/scanner repo parity. It explicitly stays inside the current parser-only generated surface.

## Goal

- [x] define the parser-only repo shortlist and acceptance rules
- [ ] add a repeatable harness that runs the current generator against real parser-only grammars/repos
- [x] record generation, compile-smoke, and structural compatibility results in one place
- [x] make known parser-only repo mismatches explicit instead of anecdotal
- [x] establish concrete exit criteria for “parser-only compatibility coverage exists”

## Progress Update

The first implementation slice is now landed, but it is intentionally narrower than the full milestone goal:

- a staged in-repo parser-only shortlist now exists under `compat_targets/`
- a reusable harness now exists under `src/compat/`
- the harness records structured per-target results, compile-smoke status, compatibility-check status, and aggregate JSON reporting
- the current staged target set is still repo-local bootstrap coverage, not yet the real external repo shortlist described by this milestone

The second implementation slice is now landed as well:

- `compat_targets/shortlist.json` now records explicit selection rules, disqualification rules, candidate status, and success criteria
- the compatibility target model now distinguishes intended first-wave, deferred later-wave, and excluded out-of-scope candidates
- the harness can now run the full versioned shortlist and report excluded scanner-boundary candidates explicitly instead of leaving them implicit
- the JSON report now aggregates concrete mismatch categories instead of only broad pass/fail buckets

The third implementation slice is now landed as well:

- `src/compat/inventory.zig` now derives an explicit parser-only boundary summary from actual shortlist runs
- the repo now has one generated inventory/report surface that separates:
  - first-wave boundary counts
  - in-scope non-passing targets
  - deferred later-wave targets
  - out-of-scope scanner-boundary targets
- the current parser-only compatibility boundary can now be stated from harness results instead of being inferred from scattered tests

The fourth implementation slice is now landed as well:

- the full shortlist run report is now also checked in as:
  - `compat_targets/shortlist_report.json`
- tests now lock both the boundary summary artifact and the full shortlist run report artifact to the current rendered harness output
- generation, compile-smoke, structural-compatibility, and classification results now live in one versioned machine-readable artifact instead of only in test-only memory

The fifth implementation slice is now landed as well:

- a dedicated classified mismatch inventory is now also checked in as:
  - `compat_targets/shortlist_mismatch_inventory.json`
- the current shortlist outcome is now explicit in one place:
  - 0 non-passing first-wave parser-only targets
  - 1 deferred later-wave target
  - 1 out-of-scope external-scanner target
- tests now lock the mismatch-inventory artifact to the current rendered classification output

The sixth implementation slice is now landed as well:

- a checked-in closeout decision artifact now captures the current parser-only boundary and recommended next milestone:
  - `compat_targets/coverage_decision.json`
- tests now lock that decision artifact to the current rendered closeout summary
- the milestone can now answer in one place:
  - what parser-only coverage is currently proven
  - what parser-only targets remain deferred
  - what remains explicitly out of scope because it belongs to scanner/external-scanner coverage
  - what the next promoted milestone should be

## PR-Sized Slices

This section tracks the practical landing order for the milestone. Unlike the contract sections above, these slices are allowed to change as implementation sequencing changes.

### PR 1 Goal

Land the first repeatable parser-only compatibility harness without changing the public CLI.

Status: implemented.

This first slice is infrastructure-first:

- add a versioned parser-only target shortlist
- run those targets through the existing load, prepare, parse-table, emission, compile-smoke, and structural-compatibility layers
- produce one deterministic JSON report
- keep scope inside repo-local staged targets for now so the harness shape can stabilize before external repo onboarding

### PR 1 Non-Goals

- no new top-level CLI command
- no broad external-scanner or runtime-parity claims
- no corpus-walk behavioral parity
- no external repo checkout or fixture management
- no deeper parse-table minimization/compression work

### PR 1 Target Set

The first staged shortlist stays small and intentionally mixed:

- `parse_table_tiny_json`
  - smallest parser-only JSON path
  - expected to pass end to end
- `behavioral_config_json`
  - richer scanner-free JSON grammar
  - expected to pass end to end
- `repeat_choice_seq_js`
  - parser-only JS path
  - expected to exercise the staged blocked/unresolved boundary while still emitting parser surfaces

These are not the final real-repo targets for the milestone. They are the bootstrap set that lets the harness land without coupling the first PR to external repo acquisition and curation.

### PR 1 Files

Add:

- `compat_targets/parse_table_tiny/grammar.json`
- `compat_targets/behavioral_config/grammar.json`
- `compat_targets/repeat_choice_seq/grammar.js`
- `src/compat/targets.zig`
- `src/compat/result.zig`
- `src/compat/compile_smoke.zig`
- `src/compat/harness.zig`
- `src/compat/report_json.zig`

Update:

- `src/main.zig`

### PR 1 Task List

- [x] add the staged parser-only target shortlist and version the initial grammar inputs
- [x] define the structured per-target result model before wiring execution
- [x] add a reusable compile-smoke helper for emitted `parser.c`
- [x] add a compatibility harness that:
  - loads the grammar
  - prepares the grammar
  - serializes the parse table
  - emits parser tables
  - emits C tables
  - emits parser.c
  - runs structural compatibility checks
  - runs compile-smoke
  - records first failure and final classification
- [x] add deterministic JSON report rendering for the full harness run
- [x] add integration-style tests that execute the staged target set and verify the report shape

### PR 1 Acceptance Criteria

- [x] a versioned staged target shortlist exists in the repo
- [x] the harness can run the shortlist without per-target scripting
- [x] each target records step-by-step status rather than one generic pass/fail value
- [x] structural compatibility and compile-smoke are reported separately
- [x] the report is deterministic and machine-readable
- [x] at least one target passes end to end within the current staged boundary

### PR 1 Known Risks

- `grammar.js` targets depend on `node` being available on `PATH`
- the first staged targets are still repo-local, so this PR should not be presented as completion of the full real-repo coverage goal
- blocked parser surfaces need to be treated as reportable outcomes rather than accidental failures

### PR 2

- replace or augment the staged in-tree targets with a real parser-only repo shortlist
- add explicit selection and disqualification metadata for those targets
- classify out-of-scope scanner/external-scanner cases directly in the report

### PR 3

- add richer aggregate summaries and mismatch grouping
- decide whether any harness surface should graduate into a CLI command or separate tool entrypoint

## Current Starting Boundary

What already exists before this milestone:

- `src/parse_table/pipeline.zig`
  - can build prepared parse tables and generate parser-table, C-table, and parser.c-like emitted outputs
- `src/parser_emit/parser_c.zig`
  - emits the staged runtime-facing parser.c surface and now applies emitted-surface optimization/compaction
- `src/parser_emit/compat_checks.zig`
  - validates the current parser.c compatibility-sensitive structural surface
- `src/behavioral/harness.zig`
  - proves curated scanner-free, lexer-driven, and first external-token behavior on local grammars
- `src/cli/command_generate.zig`
  - can summarize optimization and emitted-surface stats, but does not yet provide real-repo compatibility reporting

What is still missing at the start of this milestone:

- there is no canonical shortlist of real parser-only grammars/repos to exercise
- there is no dedicated real-repo compatibility harness
- there is no machine-readable result record for parser-only repo runs
- there is no explicit pass/fail policy that distinguishes:
  - unsupported because scanner/external-scanner work is out of scope
  - unsupported because of a true parser-only gap
  - supported enough for the current staged boundary

## Scope Rules

This milestone is intentionally limited.

In scope:

- grammars/repos that can be exercised within the current parser-only boundary
- parser generation, emitted output generation, compile-smoke, and structural compatibility checks
- documenting parser-only gaps discovered from real grammars

Out of scope:

- full lexer/scanner repo parity
- external-scanner repo parity
- broad runtime execution parity against upstream Tree-sitter runtime behavior
- turning the top-level CLI into a complete multi-artifact product surface

## Exit Criteria

- [x] at least one parser-only repo shortlist file exists and is versioned in the repo
- [x] a repeatable harness can run that shortlist without manual per-repo scripting
- [x] the harness records per-repo outcomes for:
  - grammar load/parse
  - parse-table generation
  - parser-table emission
  - C-table emission
  - parser.c emission
  - parser.c compile-smoke
  - structural compatibility checks where applicable
- [ ] known parser-only failures are classified and documented
- [x] the repo can state a concrete current parser-only compatibility boundary based on harness results, not only fixture tests

## Implementation Sequence

### 1. Freeze the parser-only repo selection policy

- [x] define what qualifies as a parser-only candidate repo/grammar
- [x] define what disqualifies a candidate from this milestone
- [x] record selection rules in this file before adding any repo fixtures

Selection rules to make explicit:

- grammar must not require external scanners for its primary parse path
- grammar should avoid depending on runtime surfaces that this repo does not yet claim
- grammar should be small enough to keep harness iteration cheap
- shortlist should include more than one style of grammar, not only trivial examples

Disqualification rules to make explicit:

- requires external scanner support for the normal parse path
- requires broader lexer/scanner parity than the current staged surface
- depends on runtime or ABI surfaces explicitly deferred beyond current milestones
- too large or brittle to serve as a stable first-wave harness target

Intended output for this stage:

- one written selection policy in this file
- one written disqualification policy in this file
- no ambiguous “maybe parser-only enough” target choices left unstated

### 2. Create the initial parser-only repo shortlist

- [x] add a versioned shortlist file or section that enumerates the first-wave repo targets
- [x] keep the initial wave intentionally small
- [x] classify each candidate as:
  - intended first-wave target
  - deferred to later parser-only waves
  - excluded because it is outside the parser-only boundary

For each shortlisted target, record:

- repo or grammar name
- why it qualifies as parser-only for current purposes
- expected input path to the grammar source
- whether JSON-path, JS-path, or both are relevant
- what success means for this target in this milestone

Intended first-wave size:

- [x] 3 to 5 parser-only targets maximum

Concrete output for this stage:

- a shortlist that later harness code can consume
- no “we will pick some repos later” placeholder remaining

### 3. Define the result model before building the harness

- [x] define a stable per-target result schema
- [x] make the schema capture both pass/fail status and classification
- [x] keep the schema simple enough to evolve without a migration burden

Per-target result fields should include:

- target id
- source kind:
  - `grammar.json`
  - `grammar.js`
  - both
- load status
- parse/preparation status
- parse-table generation status
- parser-table emission status
- C-table emission status
- parser.c emission status
- parser.c compile-smoke status
- compatibility-check status
- optimization summary snapshot where available
- final classification:
  - passed within current boundary
  - failed due to parser-only gap
  - out of scope for scanner/external-scanner reasons
  - infrastructure/harness failure

Intended output for this stage:

- a concrete result shape that code and docs can both follow
- no ad hoc logging-only harness output

### 4. Add the parser-only repo harness skeleton

- [x] create the harness entrypoint module(s)
- [x] keep file ownership explicit
- [x] ensure the harness can run without modifying upstream target repos

Expected repo surfaces for this stage:

- `src/compat/` or another clearly named harness/module area for repo compatibility work
- tests or support helpers that can:
  - load target grammars
  - normalize target metadata
  - run pipeline generation paths
  - capture structured results

The harness should initially do only:

- locate grammar input
- load grammar
- parse grammar into prepared form
- record structured result status

It should not yet:

- claim behavioral parity
- claim scanner/external-scanner support
- hide failure categories behind one generic error bucket

### 5. Add parser generation checks for real parser-only targets

- [x] run parse-table generation on every staged shortlisted target
- [x] run parser-table emission on every staged shortlisted target
- [x] run C-table emission on every staged shortlisted target
- [x] run parser.c emission on every staged shortlisted target
- [x] record which step fails first for each target

For this stage, success means:

- the harness can produce structured per-target outcomes
- first-failure reporting is deterministic
- output generation is no longer only proven on local curated fixtures

### 6. Add compile-smoke and structural compatibility proof

- [x] compile-smoke emitted parser.c for staged parser-only targets that successfully emit parser.c
- [x] run `src/parser_emit/compat_checks.zig` validation on emitted parser.c where applicable
- [x] record compile and structural failures separately

Important distinction to preserve:

- emission success is not the same as compile success
- compile success is not the same as structural compatibility success
- structural compatibility success is not the same as runtime/behavioral parity

Intended output for this stage:

- a real-repo parser-only proof boundary that goes beyond “string goldens were emitted”

### 7. Classify and document discovered parser-only gaps

- [x] collect all non-passing results from the initial wave
- [x] group them by cause
- [x] record whether each gap is:
  - a true parser-only incompatibility
  - a grammar-loading/input-shape issue
  - a compile-surface issue
  - a harness limitation
  - actually out of scope because scanner/external-scanner work is required

Concrete mismatch categories to maintain:

- grammar input/load mismatches
- preparation/lowering mismatches
- parse-table construction gaps
- emitted-surface structural gaps
- compile-smoke failures
- intentional out-of-scope scanner/external-scanner failures

Intended output for this stage:

- one explicit parser-only mismatch inventory
- no hidden “some repos did not work” summary without classification

Current partial progress for this stage:

- the JSON report now records concrete mismatch categories:
  - grammar input/load mismatch
  - preparation/lowering mismatch
  - parse-table construction gap
  - emitted-surface structural gap
  - compile-smoke failure
  - out-of-scope scanner boundary
  - infrastructure failure
- excluded shortlist candidates are now reported explicitly as out-of-scope instead of being silently omitted
- the current generated inventory is now also checked in as:
  - `compat_targets/shortlist_inventory.json`
- the full generated shortlist run report is now also checked in as:
  - `compat_targets/shortlist_report.json`
- the classified mismatch inventory is now also checked in as:
  - `compat_targets/shortlist_mismatch_inventory.json`
- a fuller mismatch inventory for real later-wave non-passing targets is still pending

Current boundary summary from the generated inventory surface:

- the first-wave parser-only run set contains 3 targets
- all 3 current first-wave targets pass within the staged boundary
- 1 deferred later-wave target is tracked separately for future mismatch expansion
- 1 excluded out-of-scope target is tracked separately for the external-scanner boundary

### 8. Add one stable compatibility report artifact

- [x] choose one report format and keep it versioned
- [x] make the report easy to diff in CI or local runs
- [x] ensure it summarizes both:
  - per-target outcomes
  - aggregate counts

Aggregate counts should include:

- total shortlisted targets
- passed targets
- failed parser-only targets
- out-of-scope scanner/external-scanner targets
- infrastructure failures
- targets that emitted parser.c successfully
- targets that compiled parser.c successfully

This report may be:

- a checked-in golden summary for the first wave
- a deterministic generated JSON artifact
- a deterministic text report if JSON is premature

Current result:

- the deterministic generated JSON artifact now also has a checked-in golden form:
  - `compat_targets/shortlist_inventory.json`
  - `compat_targets/shortlist_report.json`
- tests now verify that the rendered inventory and full shortlist report still match those checked-in artifacts

### 9. Tighten docs to the new parser-only real-repo boundary

- [x] update milestone docs after the harness result boundary is real
- [ ] update compatibility-facing docs to distinguish:
  - curated fixture proof
  - parser-only real-repo proof
  - still-deferred scanner/external-scanner repo proof

Docs that may need follow-up after the harness exists:

- `MASTER_PLAN_2.md`
- `MILESTONES_21.md`

Current partial progress for this stage:

- `README.md` now points to the versioned parser-only shortlist and checked-in inventory artifact under `compat_targets/`
- `compatibility-matrix.md` now distinguishes:
  - curated fixture and harness proof
  - the narrower parser-only shortlist boundary
  - explicitly deferred scanner/external-scanner coverage
- `MASTER_PLAN_2.md` and `MILESTONES_21.md` now also record the explicit shortlist boundary and checked-in parser-only artifacts
- broader compatibility-facing follow-up is still pending if and when real external parser-only repo coverage lands

Important rule for this stage:

- do not upgrade claims beyond what the first-wave harness actually proves

### 10. Close out the milestone with a parser-only coverage decision

- [x] mark the first-wave repo coverage boundary complete
- [x] list the remaining parser-only targets deferred to later work
- [x] list scanner/external-scanner repo coverage explicitly as later work
- [x] decide whether the next promoted milestone should be:
  - a second-wave parser-only repo coverage milestone
  - a broader compatibility polish milestone
  - a return to deeper parse-table minimization work

Closeout decision must answer:

- what parser-only repo coverage is now proven
- what parser-only gaps remain
- what is intentionally deferred because it belongs to scanner/external-scanner coverage

Current closeout decision:

- the current first-wave parser-only boundary is complete for the staged shortlist:
  - 3 intended first-wave targets pass
- remaining parser-only target explicitly deferred:
  - `parse_table_conflict_json`
- scanner/external-scanner coverage explicitly deferred beyond this milestone:
  - `hidden_external_fields_json`
- current recommended next promoted milestone:
  - a second-wave parser-only repo coverage milestone

## Deliverables

- [ ] `MILESTONES_22.md` completed with concrete repo shortlist and classifications
- [ ] harness code for parser-only repo compatibility runs
- [ ] deterministic per-target result reporting
- [ ] deterministic aggregate compatibility report
- [ ] documented parser-only mismatch inventory
- [x] checked-in parser-only coverage decision artifact

## Non-Goals

- do not treat scanner/external-scanner repo failures as Milestone 22 regressions by default
- do not claim full Tree-sitter ecosystem compatibility
- do not blur parser-only harness outcomes with runtime behavioral parity claims
- do not expand the first wave until the harness/result model is stable
