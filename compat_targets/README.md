# Compatibility Artifacts

This directory holds the checked-in compatibility surfaces for the current staged parser-only baseline and the widened staged scanner wave.

These artifacts do not claim broad runtime parity. They capture the narrower boundary that is currently proven by the in-repo parser-only shortlist plus the promoted staged scanner/external-scanner wave tracked by the `src/compat/` harness.

Current proof layers:

- curated fixture proof
  - lowering, emitter, behavioral, and compatibility checks exercised by the main test suite
- parser-only shortlist proof
  - the current staged shortlist executed by the compatibility harness
- scanner/external-scanner onboarding proof
  - tracked explicitly as a narrow promoted multi-family wave at the first staged external-scanner boundary

Versioned artifacts:

- `shortlist.json`
  - target selection policy, boundary kind, candidate classification, and success criteria
- `shortlist_inventory.json`
  - aggregate boundary summary plus family-level coverage and explicit proven first-wave, deferred-control, deferred-scanner, and out-of-scope target sections
- `shortlist_report.json`
  - full per-target machine-readable harness report with aggregate counts and family-level coverage for the current staged boundary
- `shortlist_mismatch_inventory.json`
  - classified mismatch inventory with explicit scanner-boundary and deferred-control buckets backed by dedicated classifications
- `shortlist_shift_reduce_profile.json`
  - focused machine-readable profile for deferred targets currently blocked only by unresolved `shift_reduce` decisions, including readable symbol names, candidate-action summaries, and dominant repeated signatures
- `coverage_decision.json`
  - current closeout decision and recommended next promoted milestone
- `../update_compat_artifacts.zig`
  - rewrites the checked-in shortlist and derived report artifacts from the current code and target snapshots

Current staged boundary summary:

- 5 intended first-wave parser-only targets now pass within the staged boundary
- 2 real external parser-only snapshots have been promoted into that first-wave proven set:
  - `tree_sitter_ziggy_json`
  - `tree_sitter_ziggy_schema_json`
- 1 additional staged parser-only target remains deferred for a later wave:
  - `parse_table_conflict_json`
  - this is now treated explicitly as an intentional ambiguity/control fixture, not as an unresolved external parser-only promotion gap
- 2 staged scanner/external-scanner targets now pass within the first scanner wave:
  - `hidden_external_fields_json`
  - `hidden_external_fields_js`
  - both currently prove load, prepare, first external-boundary extraction, compatibility-safe valid-path behavior, and weaker invalid-path progress
- 2 additional staged scanner/external-scanner targets now pass in the second scanner family:
  - `mixed_semantics_json`
  - `mixed_semantics_js`
  - these targets keep extras elsewhere in the grammar while proving a narrower first-boundary path that does not depend on them

Recommended next step after this staged boundary:

- keep the parser-only and staged scanner boundaries stable while shifting the promoted roadmap toward broader compatibility polish
