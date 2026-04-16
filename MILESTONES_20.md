# MILESTONES 20 (Compatibility Hardening)

This milestone turns the post-emission, post-lexer, and post-external-scanner compatibility work into a concrete execution plan tied to the current repo surfaces.

Its purpose is to make the emitted parser surface credibly usable against expected Tree-sitter runtime-facing contracts, while keeping any remaining mismatches explicit instead of accidental.

This milestone starts from the boundary already established by:

- `src/parser_emit/compat.zig`
- `src/parser_emit/compat_checks.zig`
- `src/parser_emit/parser_c.zig`
- `src/parse_table/pipeline.zig`
- `src/behavioral/harness.zig`

It does not start from zero. It hardens the staged compatibility layer that already exists after `MILESTONES 17`, `MILESTONES 18`, and `MILESTONES 19`.

## Goal

- [x] document the remaining runtime-surface mismatches against expected Tree-sitter contracts
- [x] shrink the emitted compatibility gaps that still block credible runtime use
- [x] make ABI and compatibility-layer boundaries explicit and testable
- [x] add compatibility-oriented checks for the richer emitted parser surface

## Current Starting Boundary

What already exists before this milestone:

- `src/parser_emit/compat.zig`
  - centralizes the staged compatibility target and language-version metadata
- `src/parser_emit/compat_checks.zig`
  - validates the current parser.c-oriented compatibility surface structurally
- `src/parser_emit/parser_c.zig`
  - emits compatibility metadata, language/runtime accessors, and the current staged parser surface
- `src/parse_table/pipeline.zig`
  - exercises parser emission and compatibility validation on ready and blocked parser outputs
- `src/behavioral/harness.zig`
  - provides deterministic behavioral proof for the current staged scanner-free, lexer-driven, and first external-token boundaries

What is still visibly incomplete at the start of this milestone:

- the repo does not yet have one canonical mismatch inventory for parser/runtime compatibility
- compatibility checks still focus mainly on parser.c surface structure, not a broader documented contract
- the CLI surface does not yet expose the richer compatibility work as a credible top-level generate contract
- compatibility-sensitive behavioral proof exists in pieces, but is not yet framed as one explicit compatibility boundary

## Implementation Sequence

### 1. Freeze the current compatibility mismatch inventory

- [x] audit the staged compatibility boundary in:
  - `src/parser_emit/compat.zig`
  - `src/parser_emit/compat_checks.zig`
  - `src/parser_emit/parser_c.zig`
  - `src/parse_table/pipeline.zig`
  - `src/behavioral/harness.zig`
- [x] record the remaining mismatches in one place instead of leaving them scattered across milestone notes
- [x] classify each mismatch as:
  - ready to fix in this milestone
  - intentionally deferred beyond this milestone
  - blocked on later runtime or optimization work

Current intended output for this stage:

- a concrete mismatch list in this file, not only implied by older milestone closeout text
- no implicit “known rough edges” left scattered across `MILESTONES_17.md`, `MILESTONES_18.md`, and `MILESTONES_19.md`
- a stable boundary between what this repo claims today and what is still deferred

Concrete mismatch categories to inventory first:

- parser/runtime object-shape gaps relative to expected Tree-sitter-facing contracts
- accessor and metadata gaps not yet checked by `src/parser_emit/compat_checks.zig`
- gaps between the emitted parser surface and the top-level CLI contract described in docs
- behavior-level compatibility gaps that are not visible from structural parser.c checks alone

Audited mismatch inventory for the start of `MILESTONES 20`:

1. Ready to fix in this milestone

- top-level contract drift between docs and implementation
  - `README.md`, `MASTER_PLAN.md`, and `compatibility-matrix.md` still describe a stronger generate-time contract than the current CLI actually exposes
  - current implementation fact:
    - `src/cli/command_generate.zig` primarily validates, dumps prepared IR, dumps `node-types.json`, and writes `node-types.json`
    - it does not currently expose emitted `parser.c`, emitted `grammar.json`, or compatibility reporting as first-class top-level generate outputs
- compatibility policy exists, but the canonical mismatch list does not
  - `src/parser_emit/compat.zig` centralizes target/layer/version metadata
  - the repo still lacks one explicit place that says which runtime-facing gaps remain open and which are intentionally deferred
- compatibility checks are narrower than the emitted staged surface
  - `src/parser_emit/compat_checks.zig` already enforces language metadata, parser/runtime accessors, compatibility accessors, symbol accessors, and runtime-state accessors
  - this still needs to be reviewed against the full emitted surface in `src/parser_emit/parser_c.zig` so the repo can say which emitted accessors are truly part of the staged public contract and which are only helper detail
- behavioral proof is staged, but not yet framed as one compatibility boundary
  - `src/behavioral/harness.zig` already proves deterministic behavior for:
    - scanner-free `behavioral_config`
    - lexer-driven `repeat_choice_seq`
    - first external-token `hidden_external_fields`
  - what is missing is the compatibility-oriented framing that ties those proofs back to the parser/runtime contract being claimed

2. Intentionally deferred beyond this milestone

- full upstream Tree-sitter runtime ABI parity
  - this was explicitly deferred in `MILESTONES_17.md`, `MILESTONES_18.md`, and `MILESTONES_19.md`
  - the current staged layer is compatibility-oriented, not a claim of direct upstream ABI parity
- full upstream `parser.c` parity
  - `src/parser_emit/parser_c.zig` emits a runtime-facing parser.c-like surface, but the milestone history still treats exact upstream layout and surface parity as deferred
- full scanner/runtime lifecycle parity
  - `MILESTONES_18.md` and `MILESTONES_19.md` explicitly stop short of emitted lexer/scanner C runtime parity and fuller external-scanner lifecycle parity
- ecosystem-wide grammar and corpus equivalence
  - the current behavioral harness is curated and local
  - broad repo-wide or ecosystem-wide behavioral equivalence remains later work

3. Blocked on later runtime or optimization work

- optimization-sensitive compatibility claims
  - parse-table compression/minimization is still deferred to `MILESTONES 21`
  - compatibility work should not assume a future compressed layout before the current staged contract is stabilized
- broader CLI/output-surface completion
  - some contract drift can be fixed by docs during this milestone
  - fully exposing richer outputs through the top-level CLI is a larger product-surface change than the first compatibility-hardening pass
- deeper compile-and-run runtime proof
  - `MILESTONES_17.md` established compile smoke tests for emitted `parser.c`
  - stronger runtime execution proof against a fuller runtime surface depends on work beyond the current staged structural checks

Closeout result for Step 1:

- the staged compatibility boundary has now been audited against the current repo
- the remaining mismatch set is explicitly recorded here instead of only implied by earlier milestone closeout notes
- the next steps in `MILESTONES 20` can now work from a fixed mismatch inventory instead of a vague compatibility target

### 2. Centralize the compatibility contract around the existing parser_emit boundary

- [x] keep `src/parser_emit/compat.zig` as the single source of truth for staged compatibility metadata
- [x] move any remaining compatibility assumptions out of incidental emitter text and into explicit compatibility helpers or data structures
- [x] make it clear which parts of `src/parser_emit/parser_c.zig` are:
  - staged compatibility contract
  - parser-emitter implementation detail
  - intentionally deferred upstream-parity work

Current intended output for this stage:

- one explicit compatibility surface that later behavioral work can target
- fewer compatibility decisions encoded only as parser-emitter layout accidents
- versioning and compatibility-layer decisions that are deterministic and reviewable

Concrete repo boundary for this stage:

- `src/parser_emit/compat.zig` owns target/layer/version policy
- `src/parser_emit/parser_c.zig` consumes that policy rather than inventing it ad hoc
- `src/parser_emit/compat_checks.zig` validates the public staged compatibility surface, not random emitter details

Current result for this stage:

- `src/parser_emit/compat.zig` now owns the centralized staged contract prelude:
  - generated parser/runtime compatibility comments
  - language-version and minimum-compatible-version macros
  - symbol/action/unresolved kind constants
  - staged public typedefs such as `TSSymbolInfo`, `TSCompatibilityInfo`, `TSParser`, `TSParserRuntime`, and `TSLanguage`
- `src/parser_emit/compat.zig` now also owns the centralized staged accessor surface:
  - language accessors
  - compatibility accessors
  - runtime accessors
  - parser/symbol accessors
- `src/parser_emit/parser_c.zig` now consumes that centralized contract surface instead of re-declaring it inline
- this makes the split clearer:
  - `compat.zig`:
    - staged compatibility contract and policy
  - `parser_c.zig`:
    - parser-emitter implementation details driven by serialized tables
  - still deferred:
    - fuller upstream parser layout parity
    - direct upstream runtime ABI parity

### 3. Extend structural compatibility checks on emitted parser output

- [x] extend `src/parser_emit/compat_checks.zig` to cover the compatibility-sensitive parser surface that is currently emitted but not fully enforced
- [x] keep the checks focused on runtime-facing contracts such as:
  - language-level metadata
  - parser/runtime/compatibility access paths
  - deterministic symbol-table-facing surface
  - other emitted accessors that this repo intends to treat as part of the staged public contract
- [x] ensure `src/parse_table/pipeline.zig` continues to apply those checks to both:
  - ready parser-output fixtures
  - blocked parser-output fixtures

Current intended output for this stage:

- compatibility expectations are enforced directly by tests
- structural regressions fail before broader behavioral comparison is needed
- ready and blocked parser outputs remain checked against the same staged contract

Concrete existing proof surface to extend:

- `src/parse_table/pipeline.zig`
- `src/tests/fixtures.zig`
- ready and blocked parser.c-like goldens already used by the parser-emission pipeline

Current result for this stage:

- `src/parser_emit/compat_checks.zig` now enforces not only the metadata shell, but also the staged state-table/query surface exposed by emitted parser output
- the structural check now covers:
  - runtime summary accessors such as:
    - `ts_parser_runtime_is_blocked(...)`
    - `ts_parser_runtime_has_unresolved_states(...)`
  - parser state accessors such as:
    - `ts_parser_state(...)`
    - `ts_parser_actions(...)`
    - `ts_parser_gotos(...)`
    - `ts_parser_unresolved(...)`
    - their corresponding count and indexed-entry accessors
  - query helpers such as:
    - `ts_parser_find_action(...)`
    - `ts_parser_find_goto(...)`
    - `ts_parser_find_unresolved(...)`
    - `ts_parser_has_action(...)`
    - `ts_parser_has_goto(...)`
    - `ts_parser_has_unresolved(...)`
- `src/parse_table/pipeline.zig` was already applying compatibility validation to both ready and blocked parser outputs, so this stronger structural contract is now enforced across both paths without needing a separate wiring change

### 4. Add focused compatibility-sensitive behavioral proof

- [x] extend `src/behavioral/harness.zig` with checks that are explicitly compatibility-oriented rather than only parser-progress-oriented
- [x] use existing curated fixtures first:
  - `behavioral_config`
  - `repeat_choice_seq`
  - `hidden_external_fields`
- [x] require JSON-path and JS-path parity where the current staged contract already claims support
- [x] document anything that still cannot be proven without deeper runtime integration

Current intended output for this stage:

- the project can point to concrete compatibility proof, not only emitted-shape proof
- compatibility-sensitive behavior is validated across the current supported grammar surfaces
- remaining behavior gaps are listed explicitly rather than inferred

Concrete repo boundary for this stage:

- `src/behavioral/harness.zig` remains the first local proof harness
- this milestone strengthens that harness around compatibility-sensitive outcomes
- this milestone still does not claim broad ecosystem corpus parity or full upstream runtime ABI equivalence

Current result for this stage:

- `src/behavioral/harness.zig` now contains compatibility-oriented checks in addition to the earlier progress-oriented checks
- the curated supported subset is now explicitly checked to avoid internal contract-style failures on valid inputs, especially:
  - `unresolved_decision`
  - `missing_goto`
- the compatibility-sensitive proof now covers:
  - `behavioral_config`
  - `hidden_external_fields`
- the same compatibility-safe valid-input expectations are now exercised through:
  - the JSON path
  - the JS path
- what this still does not prove without deeper runtime integration:
  - `repeat_choice_seq` still reaches the staged `unresolved_decision` boundary on its valid path, even though it preserves deterministic parity and progress through JSON and JS paths
  - full upstream runtime ABI behavior
  - broad corpus-level equivalence across the ecosystem
  - compile-and-run equivalence against upstream generated parsers

### 5. Connect the compatibility boundary back to the documented top-level contract

- [x] reconcile the strengthened compatibility boundary with the repo-level claims in:
  - `README.md`
  - `MASTER_PLAN.md`
  - `MASTER_PLAN_2.md`
  - `compatibility-matrix.md`
- [x] make sure the docs describe the same staged compatibility level that the tests now enforce
- [x] avoid claiming top-level generate behavior that the current CLI does not actually expose

Current intended output for this stage:

- the repo docs no longer overstate or understate compatibility relative to the implementation
- the staged compatibility claims are traceable from docs to code to tests

Current result for this stage:

- `README.md` now distinguishes the current staged compatibility boundary from the stronger eventual target contract
- `compatibility-matrix.md` now explicitly separates:
  - the long-term compatibility target
  - the current staged boundary the repo can actually claim today
- `MASTER_PLAN_2.md` now records the specific staged boundary that `MILESTONES 20` is hardening
- `MASTER_PLAN.md` now states more clearly that the external contract section is the intended target contract, not a claim that the current top-level CLI already exposes every artifact end to end
- the docs now align with the implementation and tests on the main practical point:
  - parser/runtime compatibility is currently proven mostly through lower-level emitter, golden, structural, compile-smoke, and behavioral-harness coverage rather than through first-class top-level `generate` outputs

### 6. Record deferrals and closeout boundary

- [x] document what remains deferred beyond this milestone
- [x] separate remaining deferred work into:
  - deeper runtime ABI parity
  - broader ecosystem behavioral equivalence
  - CLI/output-surface completion
  - optimization/minimization work
- [x] connect only the optimization-specific leftovers to `MILESTONES 21 (Optimization Later)`

Closeout decision for this milestone should only be made when:

- the mismatch set is explicit
- the staged compatibility contract is centralized
- structural compatibility checks cover the intended emitted parser surface
- compatibility-sensitive behavioral proof exists for the current supported subset
- deferred gaps are documented as deliberate, not accidental

Current result for this stage:

- remaining deferred work beyond `MILESTONES 20` is now explicit and separated by category
- deeper runtime ABI parity still remains deferred:
  - direct upstream Tree-sitter C runtime ABI parity
  - fuller scanner/runtime lifecycle parity
  - compile-and-run equivalence against upstream generated parsers
- broader ecosystem behavioral equivalence still remains deferred:
  - broader repo-wide and ecosystem-wide corpus equivalence
  - closing the `repeat_choice_seq` staged `unresolved_decision` boundary
  - broader grammar/repo compatibility coverage beyond the current curated subset
- CLI/output-surface completion still remains deferred:
  - exposing emitted `parser.c` as a first-class top-level `generate` output
  - exposing emitted `grammar.json` as a first-class top-level `generate` output
  - exposing compatibility/reporting surfaces through the top-level CLI instead of mostly through lower-level tests and emitters
- only the optimization-specific leftovers belong directly to `MILESTONES 21 (Optimization Later)`:
  - parse-table compression/minimization
  - any table-layout changes that should happen only after the staged compatibility contract is already stable

Milestone 20 closeout decision:

- this milestone is complete as the first explicit compatibility-hardening boundary
- it now provides:
  - a centralized staged compatibility contract in `src/parser_emit/compat.zig`
  - stronger structural compatibility checks in `src/parser_emit/compat_checks.zig`
  - compatibility-sensitive behavioral proof in `src/behavioral/harness.zig`
  - repo-level docs that distinguish the current staged boundary from the eventual target contract
- it intentionally still does not claim:
  - full upstream runtime ABI parity
  - full upstream `parser.c` parity
  - full ecosystem-wide corpus equivalence
  - full top-level CLI/output parity

## Exit Criteria

- [x] the remaining compatibility mismatch set is documented in this file in one place
- [x] `src/parser_emit/compat.zig` is the clear source of truth for staged compatibility metadata and policy
- [x] `src/parser_emit/compat_checks.zig` enforces the intended emitted compatibility surface for both ready and blocked parser outputs
- [x] `src/parse_table/pipeline.zig` applies the compatibility checks to the emitted parser-output path
- [x] `src/behavioral/harness.zig` contains at least one focused compatibility-sensitive proof for the current supported subset
- [x] repo-level docs describe the same compatibility boundary that the code and tests enforce
- [x] deferred gaps are documented rather than implicit

## Explicit Non-Goals For This Milestone

- [ ] do not claim full upstream Tree-sitter runtime ABI parity here
- [ ] do not claim full ecosystem-wide grammar or corpus equivalence here
- [ ] do not use optimization or minimization work to hide unresolved compatibility questions
- [ ] do not broaden the top-level CLI contract beyond what the implementation actually supports
