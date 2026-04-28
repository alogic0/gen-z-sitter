# Gap Report 260428 Status Addendum

Source audit: `docs/audits/gap-report-260428.md`.

This addendum records findings that changed after the audit was written. The
implementation plan for remaining work is
`docs/plans/audit-findings-plan-2026-04-28.md`.

## Closed Or Superseded

- `add_primary_state_id_list` is closed. `SerializedTable.primary_state_ids` is
  built during serialization and compaction, emitted as `ts_primary_state_ids`,
  and wired into `TSLanguage.primary_state_ids`.
- Emitted parser `error_cost` is closed for generated parser output. Generated
  parse versions and `TSGeneratedParseResult` carry `error_cost`, and pruning
  uses weighted error cost. Behavioral harness parity remains tracked
  separately.
- Per-target build configuration is closed for the Haskell closure-pressure
  case. `compat_targets/tree_sitter_haskell_json/build_config.json` is loaded
  by the compatibility harness and applied during parse-table construction.
- Hardcoded Haskell closure-pressure state/symbol experiments are superseded by
  target config and no longer define the promoted path.
- Scanner-state GLR condensation is closed for emitted generated parsers:
  serialized external scanner payload length and bytes participate in version
  identity.
- Scanner-aware incremental local coverage now exists through a sampled
  Haskell-layout fixture that blocks unsafe subtree reuse when scanner-owned
  state would be required.
- Runtime recovery strategies 2 and 3 now have focused behavioral coverage for
  skip-and-relex and consecutive unrecognized-byte span accounting.
- Version pruning now carries `MAX_VERSION_COUNT_OVERFLOW`-style overflow
  behavior and prunes by weighted error cost before dynamic precedence.
- Incremental reuse guards now reject first-leaf lookahead mismatches, changed
  subtrees, fragile subtrees, error subtrees, and nested unsafe children.
- Expected-conflict equivalence now has positive and negative multi-conflict
  fixtures checked against upstream `tree-sitter generate` behavior.
- Generic runtime proof configuration is closed for the promoted runtime-link
  targets: full-link proofs now load `runtime_proof_config.json` and dispatch
  by configured proof id instead of target id.

## Still Open

- Complex scanner promotion: JavaScript, Python, TypeScript, and Rust should
  advance one boundary at a time using the stronger runtime and proof-config
  evidence.

## Measurement-Gated

- DAG-level stack replacement should wait until a focused sample shows
  version-explosion cost or behavioral divergence.
- Further SymbolSet/key compression should wait until profile artifacts show
  allocation churn again.
- Emitted C shape tuning should wait until compile time becomes a current
  blocker again.
