# MILESTONES 29 (Real External Scanner Evidence)

This milestone follows [MILESTONES_28.md](./MILESTONES_28.md).

Milestone 28 closed the current real external parser-only story. Milestone 29 starts the real external scanner story: the repo now has its first onboarded real external scanner-family target, but that evidence is still deferred behind the first unsupported external-boundary surface.

It is not a runtime-parity milestone. It is not a broad target-explosion milestone. It is not a generic scanner-refactor milestone.

## Goal

- create a machine-readable real external scanner-evidence surface
- onboard 1 to 3 real external scanner or external-scanner snapshots when local sources exist
- classify the first real external scanner blocker precisely
- promote one real external scanner target or freeze it explicitly with rationale

## Starting Point

- [x] real external evidence is now reported separately from staged fixtures
- [x] current real external evidence starts from 2 parser-only Ziggy snapshots and no promoted real external scanner targets
- [x] staged scanner proof exists across 2 in-repo scanner families
- [x] the current workspace now also contains `tree-sitter-haskell`, a real external scanner-family grammar with `src/scanner.c`

## Scope

In scope:

- dedicated artifact/reporting for real external scanner evidence
- onboarding real external scanner targets when local sources are available
- precise classification of the first exposed real external scanner blocker
- doc updates needed to keep staged and real scanner evidence distinct

Out of scope:

- claiming full runtime or corpus parity
- broad scanner target-count expansion without local source availability
- major parser/scanner refactors without direct real-evidence payoff
- broad CLI surfacing of compatibility artifacts

## Exit Criteria

- [x] the checked-in artifacts expose real external scanner evidence separately from staged scanner fixtures
- [x] at least one real external scanner target is onboarded or the local-source limitation is recorded explicitly in milestone and artifact form
- [x] the current real external scanner gap is stated directly in repo docs and artifacts
- [x] the milestone ends with a clearer real external scanner story than it started with

## PR-Sized Slices

### PR 1

Goal:

- add a dedicated real external scanner-evidence artifact

Checklist:

- [x] add a compatibility report surface that filters the shortlist down to external scanner/external-scanner snapshots
- [x] expose the current zero-state and local-source limitation explicitly when no local external scanner targets exist
- [x] regenerate checked-in compatibility artifacts
- [x] keep `zig build test` passing

Acceptance:

- [x] the repo has a machine-readable real external scanner-evidence artifact even before the first real scanner snapshot is onboarded

### PR 2

Goal:

- onboard or explicitly classify the first real external scanner target slice

Checklist:

- [x] inspect available local real scanner grammar sources
- [x] choose 1 to 3 high-value real external scanner targets or record why none are locally available yet
- [x] add target metadata and snapshots if a new local real scanner target exists, or record the current local-source limitation explicitly
- [x] regenerate checked-in artifacts
- [x] keep `zig build test` passing

Acceptance:

- [x] the milestone either grows the real external scanner target set or records the current local-source limitation explicitly instead of leaving the gap implicit

### PR 3

Goal:

- land one narrow real external scanner improvement

Checklist:

- [ ] choose one concrete real external scanner improvement
- [x] choose one concrete real external scanner improvement
  - promote one new real external scanner target
  - narrow one newly exposed scanner blocker
  - freeze one real external scanner target with explicit rationale if promotion is not justified
- [x] implement or document the narrower outcome
- [x] regenerate checked-in artifacts if needed
- [x] update milestone/docs to match
- [x] keep `zig build test` passing

Acceptance:

- [x] the milestone ends with a stronger and more explicit real external scanner claim than it started with

### PR 4

Goal:

- close out the milestone decision cleanly

Checklist:

- [x] update milestone progress and closeout language
- [x] update any affected compatibility docs
- [x] keep the real external scanner next-step recommendation explicit

Acceptance:

- [x] the milestone closes without confusing staged scanner proof with real external scanner evidence

## Progress Checklist

- [x] PR 1 completed
- [x] PR 2 completed
- [x] PR 3 completed
- [x] PR 4 completed
- [x] M29 ready for closeout

## Non-Goals

- do not present staged scanner fixtures as real external scanner evidence
- do not claim runtime equivalence from first-boundary artifact checks
- do not fabricate a real scanner wave when the local workspace does not contain the source material
- do not hide missing local real scanner repos behind vague milestone language

## Current PR 2 Note

- the local real grammar repos currently available under `/home/oleg/prog/tree-sitter-grammars` are:
  - `tree-sitter-c`
  - `tree-sitter-zig`
  - `tree-sitter-haskell`
- `tree-sitter-haskell` is now onboarded into the shortlist as:
  - `tree_sitter_haskell_json`
  - upstream revision `0975ef72fc3c47b530309ca93937d7d143523628`
  - real external scanner-family evidence with `src/scanner.c`
- `tree-sitter-c` and `tree-sitter-zig` still do not currently help for this milestone:
  - both `src/grammar.json` snapshots declare `"externals": []`
  - neither repo currently contains `scanner.c`, `scanner.cc`, `scanner.cpp`, or `scanner.js`
- the first observed Haskell blocker is now explicit:
  - it now passes structural first external-boundary extraction
  - the current deferred boundary is the broader sampled scanner check, which still requires stateful multi-token external-scanner modeling beyond the current harness
- the current PR 3 reduction already landed:
  - `aliased_external_step`, `non_leading_external_step`, and the raw `multiple_external_tokens` count no longer block structural first-boundary extraction on their own
- PR 2 therefore ends with one onboarded real external scanner target plus an explicit first blocker classification

## PR 3 Outcome

- `tree_sitter_haskell_json` is the concrete PR 3 target
- the current harness now distinguishes 2 scanner-boundary modes:
  - staged scanner fixtures continue to use sampled behavioral checks
  - `tree_sitter_haskell_json` is now classified as structural-first-boundary-only for M29
- that means the current real external scanner claim is stronger and narrower at the same time:
  - stronger because the serializer now tolerates the broader structural external-boundary surface
  - narrower because the remaining deferred point is stated explicitly as broader stateful multi-token external-scanner modeling, not as a generic unsupported-feature list

## Closeout

- M29 now ends with:
  - a dedicated real external scanner artifact surface
  - one onboarded real external scanner target with upstream provenance
  - an explicit distinction between staged sampled scanner proof and real external structural-first-boundary proof
- the current real external scanner boundary is:
  - `tree_sitter_haskell_json` proves load, prepare, and structural first-boundary extraction
  - deeper sampled scanner-boundary simulation remains deferred pending broader stateful multi-token external-scanner modeling
