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

## Current Status

Milestone 8 is well underway and already has its main boundary changes in code.

Implemented now:

- builder-owned resolved actions in `src/parse_table/build.zig`
- pipeline/debug consumption of builder-owned resolved actions instead of re-deriving them downstream
- explicit reduce/reduce policy boundary in the resolved-action layer via `reduce_reduce_deferred`
- richer shift-side precedence support at the direct resolver boundary:
  - shift-side integer precedence from current-state steps
  - shift-side named precedence from current-state steps

What this means:

- Milestone 8 is no longer blocked on ownership/infrastructure
- the main remaining question is whether there is enough real semantic work left to justify another expansion before closeout

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

## Review Result

After the current Milestone 8 work, the remaining gaps are narrower than they were at kickoff.

Implemented during Milestone 8:

- build-time ownership of resolved actions
- explicit reduce/reduce deferral boundary in code and artifacts
- shift-side precedence no longer limited to:
  - default shift precedence of `0`
  - direct symbol ordering only

Real semantic gaps still remaining:

### 1. Shift-side precedence is improved, but still not full upstream semantics

Current state:

- the resolver can inspect current-state shift-side step metadata for:
  - integer precedence
  - named precedence

Remaining gap:

- shift-side semantics are still a narrow supported subset rather than a full upstream-equivalent model

Assessment:

- this is a real remaining semantic gap
- but it is now materially smaller than it was at Milestone 8 start

### 2. Reduce/reduce remains intentionally deferred

Current state:

- reduce/reduce is no longer merely unresolved by accident
- it is now explicitly classified as `reduce_reduce_deferred`

Remaining gap:

- no supported reduce/reduce resolution policy exists

Assessment:

- this is still a real semantic gap
- but it is now a clear milestone boundary rather than unfinished infrastructure

### 3. Priority policy is still intentionally narrow

Current state:

- the supported priority subset is implemented and test-covered:
  - integer precedence
  - named precedence
  - dynamic precedence
  - associativity
  - dynamic precedence outranking named precedence on the reduce side

Remaining gap:

- the broader precedence-priority matrix is not exhaustively modeled or documented

Assessment:

- this is partly semantic and partly closeout/documentation work

## Remaining Work Before Closeout

The remaining work now looks like this:

### Real semantic work

- decide whether to add one more focused precedence-priority rule beyond the current tested subset
- decide whether reduce/reduce should remain deferred for this milestone or gain a narrow policy

### Closeout work

- update this checklist to completion state if no further semantic expansion is chosen
- update `README.md` with the actual Milestone 8 implemented subset
- document the remaining parser-decision semantics for the later serialization milestone

## Main Targets

### 1. Shift-side precedence semantics

Current state:

- implemented for the current supported subset
- the resolver can now inspect current-state shift-side step metadata for:
  - integer precedence
  - named precedence

Target state:

- model shift-side precedence more explicitly from the shifted production context where needed
- avoid overfitting all precedence behavior to reduce-side metadata alone

Acceptance criteria:

- completed for the current supported subset at the direct resolver boundary

### 2. Reduce/reduce policy boundary

Current state:

- reduce/reduce is classified and preserved explicitly
- the resolved-action layer now marks it as `reduce_reduce_deferred`

Target state:

- choose one:
  - implement a narrow supported reduce/reduce policy if there is a clear upstream-aligned subset worth adding now, or
  - formalize reduce/reduce as intentionally unresolved for the current parser-decision boundary and make that policy explicit in code/docs/artifacts

Acceptance criteria:

- the repository has a clear, documented answer for reduce/reduce semantics rather than an implicit omission

### 3. Builder-owned resolved actions

Current state:

- implemented
- `BuildResult` now owns:
  - productions
  - precedence orderings
  - raw states
  - raw actions
  - resolved actions

Target state:

- `BuildResult` should own resolved actions as well, or provide an equivalent first-class resolved surface directly from the builder

Acceptance criteria:

- completed

### 4. Priority policy documentation and coverage

Current state:

- the supported precedence-priority subset works and is test-covered
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

1. Decide whether Milestone 8 needs one more semantic rule beyond the current supported subset.
2. If not, mark the milestone complete and move the remaining parser-decision gaps to the next milestone.
3. If yes, keep the addition narrowly scoped and artifact-tested.

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
