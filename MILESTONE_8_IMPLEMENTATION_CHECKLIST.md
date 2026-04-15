# Milestone 8 Implementation Checklist

## Goal

Implement the next parser-decision milestone after Milestone 7:

- extend the parser-table layer beyond the current supported shift/reduce resolution subset
- improve semantic fidelity around shift-side precedence and unresolved conflict policy
- move resolved parser decisions closer to the builder boundary
- prepare a cleaner handoff to later parse-table serialization and `parser.c` emission work

Milestone 8 is the bridge between:

- “we can resolve a useful, well-tested subset of conflicts”

and

- “the build layer owns stable parser decisions that are credible inputs to later serialization/code emission”.

## What Milestone 8 Includes

- richer shift-side precedence modeling
- an explicit decision about reduce/reduce policy:
  - implement a narrow supported subset, or
  - formalize it as an intentional unresolved boundary with stronger structure
- builder-owned resolved-action output in `BuildResult`, or an equivalent first-class build-time resolved surface
- a clearer documented priority policy across:
  - integer precedence
  - named precedence
  - dynamic precedence
  - associativity
- exact artifacts that prove the new semantic boundary through the full preparation path

## What Milestone 8 Does Not Include

- final parse-table serialization
- `parser.c` rendering
- lexer/scanner code emission
- parse-table minimization
- full generator parity

Those belong to later milestones once the build-time decision boundary is stable.

## Starting Point

Milestone 7 already provides:

- resolved-action table IR
- exact resolved-action dump artifacts
- explicit unresolved classification
- integer precedence in both directions
- named precedence in both directions when directly ordered against the conflicted symbol
- dynamic precedence in both directions
- dynamic precedence priority over named precedence on the reduce side
- equal-precedence associativity handling
- explicit unresolved shift/reduce and reduce/reduce cases

What Milestone 7 intentionally leaves incomplete:

- richer shift-side precedence semantics
- reduce/reduce resolution policy
- builder-owned resolved actions in `BuildResult`
- broader precedence-priority policy beyond the currently tested subset

## Main Targets

### 1. Shift-side precedence semantics

Current state:

- shift/reduce resolution primarily uses reduce-side metadata
- the shift side is represented by:
  - the default shift precedence of `0`, or
  - direct ordering against the conflicted shift symbol

Target state:

- model shift-side precedence more explicitly from the shifted production context where needed
- avoid overfitting all precedence behavior to reduce-side metadata alone

Acceptance criteria:

- at least one focused fixture proves a decision that depends on richer shift-side precedence rather than only reduce-side metadata

### 2. Reduce/reduce policy boundary

Current state:

- reduce/reduce is classified and preserved explicitly
- no supported resolution policy exists yet

Target state:

- choose one:
  - implement a narrow supported reduce/reduce policy if there is a clear upstream-aligned subset worth adding now, or
  - formalize reduce/reduce as intentionally unresolved for the current parser-decision boundary and make that policy explicit in code/docs/artifacts

Acceptance criteria:

- the repository has a clear, documented answer for reduce/reduce semantics rather than an implicit omission

### 3. Builder-owned resolved actions

Current state:

- `BuildResult` owns:
  - productions
  - precedence orderings
  - raw states
  - raw actions
- resolved actions are derived later in the pipeline

Target state:

- `BuildResult` should own resolved actions as well, or provide an equivalent first-class resolved surface directly from the builder

Acceptance criteria:

- later stages no longer need to reconstruct resolution policy independently from builder output

### 4. Priority policy documentation and coverage

Current state:

- the current precedence-priority subset works and is test-covered
- but the broader policy remains intentionally narrow

Target state:

- document the intended order/priority among:
  - dynamic precedence
  - integer precedence
  - named precedence
  - associativity
- add focused fixtures only where the policy is actually implemented

Acceptance criteria:

- the supported priority matrix is explicit in both docs and tests

## File-by-File Plan

### 1. `src/parse_table/resolution.zig`

Purpose:

- extend parser-decision semantics beyond the Milestone 7 subset

Implement:

- richer shift-side precedence extraction or comparison helpers
- any newly supported reduce/reduce policy, if added
- explicit precedence-priority helpers rather than growing ad hoc conditional order

Acceptance criteria:

- semantic decisions are easier to read and reason about than the current incremental chain

### 2. `src/parse_table/build.zig`

Purpose:

- own resolved parser decisions at build time

Implement:

- builder-owned resolved actions in `BuildResult`, or an equivalent first-class resolved surface
- any wiring needed to pass richer precedence information into resolution

Acceptance criteria:

- pipeline/debug layers consume builder-owned resolved data instead of re-deriving it ad hoc

### 3. `src/parse_table/debug_dump.zig`

Purpose:

- expose the build-time resolved boundary clearly

Implement:

- update resolved-action dumps to consume builder-owned resolved output where appropriate
- keep unresolved reasons visible

Acceptance criteria:

- exact artifact output remains stable and readable after the boundary shift

### 4. `src/parse_table/pipeline.zig`

Purpose:

- prove the new Milestone 8 semantics through the full preparation path

Implement:

- exact goldens for any new shift-side precedence or reduce/reduce policy cases
- exact goldens for builder-owned resolved output if the boundary moves

Acceptance criteria:

- every new supported semantic rule is pinned end to end

### 5. `src/tests/fixtures.zig`

Purpose:

- isolate the remaining parser-decision semantics cleanly

Implement:

- only the focused fixtures needed to pin:
  - richer shift-side precedence
  - any reduce/reduce policy
  - any new precedence-priority interactions

Acceptance criteria:

- no broad “kitchen sink” fixtures unless they expose a real new semantic gap

## Recommended Implementation Order

1. Decide whether Milestone 8 will implement a reduce/reduce policy or explicitly formalize its deferral boundary.
2. Add a focused fixture that requires richer shift-side precedence.
3. Refactor `src/parse_table/resolution.zig` so precedence-priority rules are explicit and composable.
4. Move resolved actions into `BuildResult`, or add an equivalent first-class build-time resolved surface.
5. Update dumps/pipeline tests to consume the new build-time boundary.
6. Do a closeout review documenting what parser-decision semantics are stable before the later serialization milestone.

## Risks

- shift-side precedence can expand quickly if modeled too broadly at once
- reduce/reduce policy may not have a worthwhile narrow subset and could waste time if forced prematurely
- moving resolved actions into the builder can create churn in artifact code if done before the semantic boundary is clear

## Exit Criteria

Milestone 8 is complete when:

- the remaining parser-decision semantics chosen for this milestone are implemented and test-covered
- the builder owns resolved parser decisions, or exposes an equivalent first-class resolved surface
- the supported priority policy is explicit in both code and docs
- remaining unresolved parser-decision semantics are clearly documented for the later serialization/code-emission milestone
