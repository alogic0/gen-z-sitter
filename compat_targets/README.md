# Parser-Only Compatibility Artifacts

This directory holds the checked-in parser-only compatibility surfaces for the current staged Milestone 22 boundary.

These artifacts do not claim broad external-repo or scanner/external-scanner compatibility. They capture the narrower boundary that is currently proven by the in-repo parser-only shortlist and the `src/compat/` harness.

Current proof layers:

- curated fixture proof
  - lowering, emitter, behavioral, and compatibility checks exercised by the main test suite
- parser-only shortlist proof
  - the current staged shortlist executed by the compatibility harness
- scanner/external-scanner proof deferred
  - tracked explicitly, but not promoted as part of the current parser-only boundary

Versioned artifacts:

- `shortlist.json`
  - target selection policy, candidate classification, and success criteria
- `shortlist_inventory.json`
  - aggregate boundary summary for the current shortlist run
- `shortlist_report.json`
  - full per-target machine-readable harness report
- `shortlist_mismatch_inventory.json`
  - classified mismatch and deferred/out-of-scope inventory
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
- 1 external-scanner target is tracked explicitly as out of scope

Recommended next step after this staged boundary:

- treat the remaining staged deferred conflict target as a frozen control case unless a later milestone intentionally expands conflict-resolution policy
