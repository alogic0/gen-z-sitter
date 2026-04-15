# Milestone 4 Implementation Checklist

## Goal

Implement the next parity-focused stage after the Milestone 3 `node-types.json` pipeline:

- close the known `node-types.json` mismatches that were explicitly deferred from Milestone 3
- align `compute.zig` more closely with upstream `node_types.rs`
- preserve the current deterministic artifact pipeline while improving upstream compatibility
- leave the project in a better position for later parser-generation milestones

Milestone 4 is not about adding a brand-new artifact. It is about tightening semantic parity at the existing artifact boundary before broader generator work resumes.

## What Milestone 4 Includes

- `children_without_fields` parity in node-type computation
- named lexical/external collision parity in node-type merging
- stronger separation between internal variable summaries and emitted JSON semantics
- broader upstream-style tests for node-type structure
- CLI and pipeline golden updates where the corrected semantics intentionally change output

## What Milestone 4 Does Not Include

- parse-table generation
- lexer table generation
- `parser.c` rendering
- full `grammar.js` execution support if still deferred
- report/state dumping parity

Those remain later milestones.

## Upstream Reference Points

Milestone 4 should be guided primarily by:

- `/home/alogic0/prog/tree-sitter/crates/generate/src/node_types.rs`
- `/home/alogic0/prog/tree-sitter/crates/generate/src/prepare_grammar/extract_default_aliases.rs`
- `/home/alogic0/prog/tree-sitter/crates/generate/src/prepare_grammar/extract_tokens.rs`

The most important upstream concepts to preserve are:

- `children` in JSON are based on `children_without_fields`, not the full visible-child set
- named lexical and external node entries are added as leaf node types
- when multiple rules/aliases share the same emitted node-type name, field and child requiredness is weakened appropriately

## Deliverables

By the end of Milestone 4, the repository should have:

- `src/node_types/compute.zig` updated for `children_without_fields` parity
- any supporting IR helpers added only if they clearly simplify the node-type logic
- updated curated fixtures in `src/tests/fixtures.zig`
- updated pipeline and CLI goldens that intentionally reflect the corrected upstream behavior
- a short closeout note describing what parity improved and what still remains for later milestones

## Main Parity Targets

### 1. `children_without_fields` parity

Current state:

- `src/node_types/compute.zig` aggregates all visible children into `children`

Target state:

- `children` in emitted node types should be based only on named visible children that do not belong to fields
- fielded children should contribute to `fields`, not to the top-level `children` bucket
- hidden-wrapper inheritance should preserve this distinction rather than flattening everything together

Expected impact:

- many current goldens will intentionally change
- several node types will lose broad `children` sets and become closer to upstream output

### 2. named lexical/external collision parity

Current state:

- duplicate node-type entries are merged by `(type, named)`
- named lexical collisions can leave self-child shapes like `term -> term` or `space -> space`

Target state:

- named lexical and external entries should behave more like upstream leaf node additions
- when a syntax node and lexical node share a final emitted name, required field/child flags should be weakened correctly instead of merging into self-child recursion
- duplicate merging should preserve deterministic output without inventing structure that upstream does not emit

Expected impact:

- `term`, `space`, and similar node types may stop emitting self-child `children`
- some existing “merged” node types may become structurally smaller

## File-by-File Plan

### 1. `src/node_types/compute.zig`

Purpose:

- implement the deferred upstream node-type semantics

Implement:

- split internal summary tracking into:
  - all visible children
  - children associated with fields
  - named children without fields
- change emitted `NodeType.children` to derive from the no-field child set
- revisit merge behavior for same-name node types so lexical/external collisions weaken requiredness instead of creating self-child artifacts
- keep supertype handling, alias handling, and hidden-wrapper inheritance deterministic

Acceptance criteria:

- fixtures that currently over-report `children` are corrected intentionally
- named lexical collision cases no longer create self-child artifacts unless upstream really does

### 2. `src/tests/fixtures.zig`

Purpose:

- encode the new upstream-style expected outputs

Implement:

- update existing fixtures whose output must change:
  - baseline `validResolvedNodeTypesJson`
  - hidden-wrapper cases if needed
  - extras-plus-alias cases if needed
- add focused fixtures for:
  - fielded children vs `children_without_fields`
  - named lexical collision cases
  - named external collision cases if they differ from lexical cases

Acceptance criteria:

- fixture names make it obvious which parity behavior they are testing
- every intentional output change is anchored by a fixture, not only an inline unit test

### 3. `src/node_types/pipeline.zig`

Purpose:

- keep the artifact-level end-to-end coverage aligned with the corrected semantics

Implement:

- update exact golden comparisons to the new expected JSON
- add any new fixture-based pipeline tests needed for collision parity

Acceptance criteria:

- `generateNodeTypesJsonFromPrepared` remains fully golden-driven

### 4. `src/cli/command_generate.zig`

Purpose:

- keep the non-debug file-output path aligned with the corrected node-type semantics

Implement:

- update any CLI output goldens that intentionally change
- add one or two CLI tests for the new collision/children-without-fields fixtures if needed

Acceptance criteria:

- CLI artifact output remains covered by exact golden checks for representative grammars

## Recommended Implementation Sequence

1. Refactor `src/node_types/compute.zig` to distinguish:
   - all visible children
   - field-associated children
   - children without fields
2. Add a direct `compute.zig` regression for fielded-vs-unfielded children before touching goldens.
3. Update pipeline/fixture expectations for the intentional output changes.
4. Refine duplicate-node merging for named lexical/external collisions.
5. Add a focused collision fixture and exact golden.
6. Update CLI file-output tests for the changed outputs.
7. Do a short parity review against upstream `node_types.rs` again before closing Milestone 4.

## Risks

- changing `children` semantics will intentionally invalidate several existing goldens at once
- collision handling is easy to over-correct; fixes should be guided by upstream behavior, not by local aesthetic preferences
- hidden-wrapper inheritance and alias materialization are tightly coupled; changing one can accidentally regress the other

## Exit Criteria

Milestone 4 is complete when:

- `children_without_fields` parity is implemented or a narrower final deferral is documented with justification
- named lexical/external collision parity no longer produces the current self-child artifacts
- `zig build` passes
- `zig build test` passes
- the curated pipeline and CLI goldens reflect the corrected semantics intentionally
- the remaining known gaps, if any, are small enough to move on to later generator milestones
