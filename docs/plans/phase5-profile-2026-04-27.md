# Phase 5 Profile Snapshot - 2026-04-27

This snapshot records the first bounded Phase 5 profiling pass after Phase 4
incremental parsing work. The profiler is intentionally a build step so future
runs use the same code path:

```sh
zig build run-phase5-profile -- --target <target>
GEN_Z_SITTER_PARSE_TABLE_PROFILE=1 zig build run-phase5-profile -- --target <target>
```

The plain runner reports load, prepare, runtime serialization, parser C
emission, generated C bytes, and process MaxRSS. The env-flagged run also emits
construct-stage and allocator-churn counters from the parse-table builder.

## Bounded Results

| Target | Result | Serialize | Emit | MaxRSS | Notes |
|---|---:|---:|---:|---:|---|
| `tree_sitter_zig_json` | completed | 3748 ms | 508 ms | 362 MB | Coarse follow mode, blocked diagnostic table |
| `tree_sitter_javascript_json` | bounded serialize failure | 19205 ms | n/a | 575 MB | `ParseActionListTooLarge` before emission, after hashed action-slice dedup |
| `tree_sitter_c_json` | timed out under verbose profiling | >30 s | n/a | n/a | Construct profile reached build states and action resolution before timeout |
| `tree_sitter_rust_json` | timed out | >30 s | n/a | n/a | No summary before timeout |
| `tree_sitter_typescript_json` | timed out | >30 s | n/a | n/a | No summary before timeout |

## C JSON Construct Counters

The bounded verbose C run reached the construct profile before the 30 second
timeout:

- `build_states_total`: 3667 ms
- `construct_states`: 2967 ms
- `resolve_action_table`: 383 ms
- `assign_lex_state_ids`: 206 ms
- `states`: 15529
- `successor_groups`: 243195
- `state_intern_calls`: 15528
- `state_intern_reused`: 0
- `closure_cache_hits`: 0
- `closure_cache_misses`: 15528
- `closure_expansion_cache_hits`: 11900
- `closure_expansion_cache_misses`: 954
- `symbol_sets bool_alloc_mb`: 22.83
- `symbol_sets bool_free_mb`: 4.05

The current C profile does not justify SymbolSet compression as the next first
optimization: bool-set churn is visible but not the dominant measurement. The
stronger immediate signal is serialized parse-action list growth on JavaScript
and larger grammar end-to-end timeouts before emission.

## Follow-up

- Keep `GEN_Z_SITTER_PARSE_TABLE_PROFILE=1` for targeted construct diagnostics,
  not default bounded-suite runs.
- Treat `ParseActionListTooLarge` as an explicit large-grammar boundary rather
  than allowing Debug integer overflow.
- Keep parse-action-list packing on the Phase 5 path: hashed action-slice dedup
  improved JavaScript by about 12%, but the table still exceeds the `uint16_t`
  runtime-compatible index space.
- JavaScript parse-action-list profile: `entries=23424`, `flat_width=65537`,
  `capacity=65536`, `single_unique=4922`, `single_dupes=269277`,
  `unresolved_unique=18501`, `unresolved_dupes=4614`,
  `unresolved_flat_width=55693`, `max_actions_per_entry=6`.
- Profile Rust and TypeScript with a longer explicit diagnostic budget before
  selecting a structural optimization.
