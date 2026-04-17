# Compatibility Artifacts

This directory holds the checked-in compatibility surfaces for the current staged parser-only baseline and the widened staged scanner wave.

These artifacts do not claim broad runtime parity. They capture the narrower boundary that is currently proven by the in-repo parser-only shortlist plus the promoted staged scanner/external-scanner wave tracked by the `src/compat/` harness.

Current proof layers:

- curated fixture proof
  - lowering, emitter, behavioral, and compatibility checks exercised by the main test suite
- parser-only shortlist proof
  - the current staged shortlist executed by the compatibility harness
- staged scanner-boundary proof
  - the promoted staged scanner-wave entries in the checked-in shortlist artifacts
- real external proof
  - the promoted real external snapshots in `external_repo_inventory.json`
- real external scanner proof
  - the promoted sampled real external scanner snapshots in `external_scanner_repo_inventory.json`

Current represented families:

- parser-only
  - `parse_table_tiny`
  - `behavioral_config`
  - `repeat_choice_seq`
  - `ziggy`
  - `ziggy_schema`
  - `parse_table_conflict`
- scanner/external-scanner
  - `hidden_external_fields`
  - `mixed_semantics`
  - `haskell`
  - `bash`

Versioned artifacts:

- `artifact_manifest.json`
  - machine-readable index of compatibility artifacts and their refresh mode
  - distinguishes:
    - routine refresh artifacts produced by `../update_compat_artifacts.zig`
    - standalone probe artifacts produced outside the default refresh path
  - this is the canonical place to see which checked-in compatibility surfaces are expected to refresh routinely versus only during targeted deeper investigation
- `shortlist.json`
  - target selection policy, family, boundary kind, candidate classification, and success criteria
- `external_repo_inventory.json`
  - dedicated machine-readable inventory of the currently represented real external snapshots, including upstream provenance, represented families, boundary coverage, current real-evidence limitations, and the recommended next real-evidence step
  - this keeps real external evidence separate from the broader staged shortlist, which still includes staged fixtures and frozen controls
  - scanner-family external entries now also carry a machine-readable `proof_scope` field so narrower sampled proofs are not left implicit in prose notes alone
- `external_scanner_repo_inventory.json`
  - dedicated machine-readable inventory of real external scanner or external-scanner evidence
  - now records two passing real external scanner snapshots, their current limitations, and the recommended next scanner-evidence step
  - now also records aggregate `proof_scope_coverage` so the top-level JSON distinguishes the represented sampled scanner proof shapes before reading individual target entries
  - each entry now carries `proof_scope` so the checked-in JSON distinguishes:
    - `sampled_external_sequence`
    - `sampled_expansion_path`
- `shortlist_inventory.json`
  - aggregate boundary summary plus family-level coverage and explicit proven first-wave, deferred-control, deferred-scanner, and out-of-scope target sections
- `shortlist_report.json`
  - full per-target machine-readable harness report with aggregate counts and family-level coverage for the current staged boundary
- frozen control fixtures
  - appear in the main checked-in reports as `frozen_control_fixture` so intentionally blocked controls are not confused with ordinary staged passes
- `shortlist_mismatch_inventory.json`
  - classified mismatch inventory with explicit scanner-boundary and deferred-control buckets backed by dedicated classifications
- `shortlist_shift_reduce_profile.json`
  - focused machine-readable profile for deferred targets currently blocked only by unresolved `shift_reduce` decisions, including readable symbol names, candidate-action summaries, and dominant repeated signatures
- `parser_boundary_hypothesis.json`
  - machine-readable statement of the current narrower promotion hypothesis for deferred parser-wave targets
  - records:
    - the current proof mode
    - the proposed next proof mode
    - whether that next step belongs in routine refreshes or standalone probe tooling
    - the current decision for that hypothesis
- `coverage_decision.json`
  - current closeout decision and recommended next promoted milestone
  - now also records whether the deferred parser-wave set is currently a singleton and, when it is, which target owns that deferred slot
- `../update_compat_artifacts.zig`
  - rewrites the checked-in shortlist and derived report artifacts from the current code and target snapshots
- `../update_parser_boundary_probe.zig`
  - standalone probe runner for heavier deferred parser-only experiments
  - intentionally kept out of the routine compatibility refresh path
  - currently owns `parser_boundary_probe.json` when that deeper probe is run on purpose
  - `parser_boundary_probe.json` now records a passing coarse `serialize_only` probe for `tree_sitter_c_json`
    - current result: `serialized_state_count = 2336`
    - current result: `serialized_blocked = false`
    - this probe uses lookahead-insensitive closure expansion and is intentionally narrower than the routine shortlist boundary
  - `parser_boundary_hypothesis.json` and `coverage_decision.json` now also reflect that same standalone coarse proof machine-readably while keeping the routine shortlist classification unchanged

Current staged boundary summary:

- 5 intended first-wave parser-only targets now pass within the staged boundary
- 2 real external parser-only snapshots have been promoted into that first-wave proven set:
  - `tree_sitter_ziggy_json`
  - `tree_sitter_ziggy_schema_json`
- those same 2 real snapshots are also exposed separately in `external_repo_inventory.json` so real-repo evidence can be read without mentally subtracting the staged fixture families
- 1 additional real external parser-only snapshot is now onboarded in a deferred parser-boundary mode:
  - `tree_sitter_c_json`
  - it currently proves `load` and `prepare`
  - it is intentionally classified as `deferred_for_parser_boundary` with `parser_proof_boundary`
  - the current stable shortlist does not yet claim emitted parser surfaces, compatibility checks, or compile-smoke for this larger grammar
  - the standalone parser-boundary probe now also proves a narrower coarse `serialize_only` layer for this target without changing the routine shortlist classification
- 1 additional staged parser-only target remains deferred for a later wave:
  - `parse_table_conflict_json`
  - this is now treated explicitly as an intentional ambiguity/control fixture, not as an unresolved external parser-only promotion gap
  - the checked-in reports classify it as a `frozen_control_fixture`
- 2 staged scanner/external-scanner targets now pass within the first scanner wave:
  - `hidden_external_fields_json`
  - `hidden_external_fields_js`
  - both currently prove load, prepare, first external-boundary extraction, compatibility-safe valid-path behavior, and weaker invalid-path progress
- 2 additional staged scanner/external-scanner targets now pass in the second scanner family:
  - `mixed_semantics_json`
  - `mixed_semantics_js`
  - these targets keep extras elsewhere in the grammar while proving a narrower first-boundary path that does not depend on them
- 1 real external scanner snapshot now passes within the current sampled real scanner boundary:
  - `tree_sitter_haskell_json`
  - it is the first real external scanner-family target in the shortlist
  - it now passes structural first-boundary extraction
  - it also now passes a sampled external-sequence scanner proof layer
  - its machine-readable `proof_scope` is `sampled_external_sequence`
  - this is still narrower than full scanner.c runtime equivalence
- 1 additional real external scanner snapshot now also passes within the current sampled real scanner boundary:
  - `tree_sitter_bash_json`
  - it adds a second real external scanner family to the evidence set
  - it now passes a narrow sampled expansion path built around `_bare_dollar` and `variable_name`
  - its machine-readable `proof_scope` is `sampled_expansion_path`
  - it still does not claim sampled heredoc handling or full scanner.c runtime equivalence

Recommended next step after this staged boundary:

- keep the parser-only, staged scanner, and sampled real external scanner boundaries stable while narrowing or promoting the deferred `tree_sitter_c_json` parser-boundary target
- only after that should the roadmap shift back toward broader compatibility polish or another widened real external wave
- the current low-risk evidence decision is to keep `tree_sitter_c_json` as the only deferred parser-wave target until a narrower promotion hypothesis exists
