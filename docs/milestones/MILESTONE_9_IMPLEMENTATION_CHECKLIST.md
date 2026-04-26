# Milestone 9 Implementation Checklist

## Goal

Implement the next parser-generation milestone after Milestone 8:

- resolve the remaining meaningful parser-decision gaps that should be stabilized before serialization
- decide how far reduce/reduce policy should go before code emission work
- turn the current build-time resolved-action boundary into a credible input to parse-table serialization
- prepare the repository for the first real table-serialization / `parser.c` milestone that follows

Milestone 9 is the bridge between:

- “the builder owns resolved parser decisions for a supported subset”

and

- “the generator can serialize stable parser decisions into a later code-emission target without rethinking conflict policy”.

## Current Status

Milestone 9 is complete.

Implemented now:

- build-owned resolved actions remain the canonical parser-decision boundary
- resolved decisions now use a serializer-facing shape rather than a dump-oriented shape:
  - `ResolvedDecision`
  - per-state symbol lookup helpers
- readiness is explicit at both layers:
  - `ResolvedActionTable.isSerializationReady()`
  - `BuildResult.isSerializationReady()`
- both sides of the build-time decision surface are exposed as structured data:
  - chosen decision refs
  - unresolved decision refs
- the build layer now exposes a single serializer-facing snapshot:
  - `DecisionSnapshot`
  - `BuildResult.decisionSnapshotAlloc()`
- real-path tests now prove both:
  - a supported grammar produces a serialization-ready snapshot
  - an unresolved conflict grammar produces a blocked snapshot with explicit unresolved entries

Final Milestone 9 decisions:

- `DecisionSnapshot` is the pre-serialization handoff for later table serialization work
- `reduce_reduce_deferred` remains the explicit Milestone 9 boundary for unresolved reduce/reduce policy

What this means:

- Milestone 9 no longer has unresolved IR-shape work before serialization
- the remaining gap to the next milestone is primarily representational and policy-followup work, not build-boundary redesign

## What Milestone 9 Includes

- any remaining parser-decision semantics that are important enough not to defer further
- an explicit milestone-level answer for reduce/reduce policy:
  - narrow supported resolution subset, or
  - confirmed long-term deferral boundary
- clearer precedence-priority policy documentation across the supported subset
- build-time resolved output shaped so later table serialization can consume it directly
- focused artifact/tests proving the final pre-serialization parser-decision boundary

## What Milestone 9 Does Not Include

- final parse-table serialization format
- `parser.c` emission
- lexer/scanner code emission
- parse-table minimization
- runtime ABI work
- full generator parity

Those should follow only after the parser-decision boundary is stable enough to serialize confidently.

## Starting Point

Milestone 8 already provides:

- builder-owned resolved actions in `BuildResult`
- resolved-action artifacts derived from build-time owned data
- explicit unresolved classification including `reduce_reduce_deferred`
- supported shift/reduce resolution for:
  - integer precedence in both directions
  - named precedence in both directions when directly ordered against the conflicted symbol
  - dynamic precedence in both directions
  - dynamic precedence priority over named precedence on the reduce side
  - equal-precedence associativity handling
- direct resolver coverage for shift-side precedence metadata from current-state steps:
  - integer precedence
  - named precedence

What still remains after Milestone 8:

- broader shift-side precedence semantics if we want more upstream fidelity before serialization
- a final decision on reduce/reduce policy
- a clearer documented priority matrix for the supported subset
- a cleaner serialization-facing shape for resolved parser decisions if the current IR still feels too dump-oriented

Most of that fourth item is now implemented in Milestone 9.

## Main Targets

### 1. Final parser-decision boundary

Current state:

- the supported subset is real and well-tested
- the build layer now exposes a serializer-facing snapshot of both chosen and unresolved decisions
- some meaningful parser-decision semantics still remain intentionally narrow

Result:

- the build-time parser-decision contract is:
  - chosen decisions
  - unresolved decisions
  - `DecisionSnapshot` as the serializer-facing aggregate handoff
- remaining ambiguities are explicitly deferred rather than left implicit

Acceptance criteria:

- met

### 2. Reduce/reduce policy decision

Current state:

- reduce/reduce is explicitly marked as `reduce_reduce_deferred`
- the build/snapshot boundary now preserves that deferral as structured unresolved output

Result:

- reduce/reduce remains deferred for this milestone
- serialization-facing code must preserve it as explicit unresolved output via `reduce_reduce_deferred`

Acceptance criteria:

- met

### 3. Priority matrix clarity

Current state:

- the implemented subset works
- the priority policy across multiple precedence mechanisms is only partly documented
- the currently supported subset is already covered in code/tests, but the policy summary in docs is still thinner than the implementation

Result:

- the supported subset remains:
  - dynamic precedence
  - integer precedence
  - named precedence
  - associativity
  - shift-side precedence metadata
- the priority matrix is accepted as the current supported subset for the first serialization milestone

Acceptance criteria:

- met for the supported subset

### 4. Serialization-facing resolved IR

Current state:

- implemented in large part
- `BuildResult` owns resolved actions
- the build layer now also exposes:
  - chosen decision refs
  - unresolved decision refs
  - a single decision snapshot

Result:

- `DecisionSnapshot` is confirmed as the pre-serialization handoff
- no further IR redesign is required before starting table serialization work

Acceptance criteria:

- met

## File-by-File Plan

### 1. `src/parse_table/resolution.zig`

Purpose:

- finish or explicitly stop the parser-decision semantics before serialization

Implement:

- any last supported semantic rule chosen for Milestone 9
- explicit priority helpers if current condition ordering still feels too implicit
- final reduce/reduce policy handling for this pre-serialization stage

Acceptance criteria:

- resolution policy is explicit, bounded, and serialization-ready

### 2. `src/parse_table/build.zig`

Purpose:

- expose the serialization-facing resolved boundary cleanly

Implement:

- any refinements needed so `BuildResult` is a natural handoff point for later table serialization
- keep raw and resolved views available only if both are still needed

Acceptance criteria:

- downstream serialization work has a stable build-time contract

### 3. `src/parse_table/debug_dump.zig`

Purpose:

- keep the pre-serialization boundary inspectable

Implement:

- update dumps only if the resolved-action IR shape changes
- preserve explicit unresolved reasons if they remain part of the serialized contract

Acceptance criteria:

- exact artifacts still explain the final parser-decision boundary clearly

### 4. `src/parse_table/pipeline.zig`

Purpose:

- pin the final pre-serialization semantics through the real preparation path

Implement:

- exact goldens for any new Milestone 9 rule or policy decision
- exact proofs for the final reduce/reduce stance

Acceptance criteria:

- the pre-serialization decision surface is covered end to end

### 5. `src/tests/fixtures.zig`

Purpose:

- isolate any remaining meaningful parser-decision cases

Implement:

- only the fixtures needed to pin:
  - one last semantic increment, if any
  - the final reduce/reduce stance
  - the supported priority matrix where it still needs proof

Acceptance criteria:

- no broad fixture growth without a real semantic payoff

## Closeout Result

Milestone 9 closes with these explicit decisions:

1. `DecisionSnapshot` is the pre-serialization handoff.
2. `reduce_reduce_deferred` remains the explicit reduce/reduce boundary.
3. the supported precedence-priority subset is accepted as sufficient for the next milestone.

## Review Result

After the current implementation work, the remaining Milestone 9 items split cleanly into:

### Implemented boundary work

- serializer-facing resolved decision shape
- direct lookup helpers by state/symbol
- build-owned readiness checks
- structured chosen decision refs
- structured unresolved decision refs
- single serializer-facing decision snapshot
- real preparation-path proofs for ready vs blocked grammars

### Deferred to the next milestone

- any future reduce/reduce resolution policy beyond `reduce_reduce_deferred`
- any broader precedence-priority expansion beyond the currently supported subset
- actual table serialization format and code-emission work

### Closeout/polish work

- completed in this checklist update
- the next milestone can now focus on serialization/code emission instead of parser-decision ownership redesign

## Risks

- forcing too much semantic expansion here can delay the serialization milestone without changing the real supported boundary much
- leaving too much ambiguous can push parser-decision uncertainty into the first serialization milestone
- changing resolved IR shape too aggressively can create churn in tests and artifacts without enough payoff

## Exit Criteria

Milestone 9 is complete when:

- the remaining parser-decision questions chosen for this milestone are resolved or explicitly deferred
- the build-time resolved-action boundary is stable enough to serve as the next milestone’s serialization input
- the supported precedence/associativity/dynamic/shift-side policy is explicit in docs and tests
- the remaining gap to table serialization and code emission is primarily representational, not semantic

Status:

- complete
