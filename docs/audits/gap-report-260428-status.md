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

## Still Open

- Behavioral harness error-cost parity: some local harness decisions still use
  simple error counts or approximations where upstream uses subtree error cost.
- `MAX_VERSION_COUNT_OVERFLOW`: not yet modeled as a separate constant/surface.
- Recovery strategies 2 and 3: skip-and-relex and extend-error-span need
  focused behavioral and emitted parser parity work.
- Incremental reuse guards: first-leaf lookahead, changed, fragile, and error
  subtree guards need explicit local metadata and tests.
- Expected-conflict equivalence: local summaries exist, but a direct
  multi-conflict upstream parity proof is still missing.
- Generic runtime proof configuration: target-name dispatch still exists for
  scanner runtime-link proofs.
- Complex scanner promotion: JavaScript, Python, TypeScript, and Rust should
  advance only after the runtime and proof-config gaps above are smaller.

## Measurement-Gated

- DAG-level stack replacement should wait until a focused sample shows
  version-explosion cost or behavioral divergence.
- Further SymbolSet/key compression should wait until profile artifacts show
  allocation churn again.
- Emitted C shape tuning should wait until compile time becomes a current
  blocker again.
