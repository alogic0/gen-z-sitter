# Gap Report Closure Status — 2026-05-02

Source audit: `docs/audits/gap-report-260501.md`.
Implementation plan: `docs/plans/gap-report-260501-closure-plan.md`.

## JavaScript Reference

Reference command:

```bash
zig build run -- compare-upstream --minimize --output .zig-cache/upstream-compare-javascript-runtime --tree-sitter-dir ../tree-sitter compat_targets/tree_sitter_javascript/grammar.json
```

Current JavaScript minimized comparison:

| Field | Local | Upstream | Status |
|---|---:|---:|---|
| serialized_state_count | 1870 | 1870 | matched |
| emitted_state_count | 1870 | 1870 | matched |
| large_state_count | 387 | 387 | matched |
| small_parse_row_count | 1483 | 1483 | matched |
| small_parse_map_count | 1483 | 1483 | matched |
| lex_mode_count | 1870 | 1870 | matched |
| external_lex_state_count | 10 | 10 | matched |
| token_count | 134 | 134 | matched |
| symbol_count | 261 | 261 | matched |
| field_count | 36 | 36 | matched |
| alias_count | 4 | 4 | matched |
| production_id_count | 121 | 121 | matched |
| large_character_set_count | 3 | 3 | matched |
| keyword_lex_function_case_count | 200 | 200 | matched |
| parse_action_list_count | 3592 | 3588 | residual +4 |
| lex_function_case_count | 266 | 279 | residual -13 |

Bounded corpus samples still match local and upstream generated parsers.

## Original Audit Gaps

The 2026-05-01 audit listed six JavaScript `suspected_algorithm_gap` entries.
Current classification:

| Gap | Current Status |
|---|---|
| `large_character_set_count` 0/3 | Closed. Per-token large character sets are collected and emitted; JavaScript reports 3/3. |
| `keyword_lex_function_case_count` 201/200 | Closed. Separator-loop construction now matches upstream keyword shape; JavaScript reports 200/200. |
| `symbol_order_hash` mismatch | Closed. Emitted symbol labels and ordering now compare by normalized symbol surface and match. |
| `field_names_hash` mismatch | Closed. Field-name emission uses upstream-shaped enum constants and `NULL` sentinel. |
| `parse_action_list_count` 3592/3588 | Successor task. The residual is two unique action-list rows after parser state, large/small row, and corpus parity. |
| `lex_function_case_count` 525/279 | Successor task. The large-set and keyword-capture portions are closed; the remaining local count is lower than upstream at 266/279, indicating runtime lex minimization/start-row compatibility work rather than missing large-set emission. |

## Runtime Gate Triage

The keyword-capture work exposed a real runtime-link regression before final
closure: word-token grammars without reserved word sets skipped keyword-table
emission. That made accepted Ziggy schema and Zig samples lex keyword-shaped
strings as the word token. The fix emits keyword lex tables whenever a word
token exists and keyword-shaped string terminals are present, even if
`reserved_word_sets` is empty.

Gate evidence:

```bash
zig build test -Dtest-filter=Keyword --summary all
zig build test-release -Dtest-filter=ZiggySchemaParserAccepted --summary all
zig build test-release -Dtest-filter=ZigParserAccepted --summary all
zig build test-release --summary all
```

Final release gate result: `1520/1520` tests passed.

## Real-Grammar Promotion Wave

Python minimized comparison completed but is not promotable:

| Field | Local | Upstream |
|---|---:|---:|
| symbol_count | 275 | 273 |
| serialized_state_count | 2812 | 2788 |
| emitted_state_count | 2811 | 2788 |
| large_state_count | 193 | 185 |
| parse_action_list_count | 4900 | 4864 |
| lex_function_case_count | 128 | 150 |
| keyword_lex_function_case_count | 162 | 162 |
| large_character_set_count | 2 | 2 |
| external_lex_state_count | 19 | 19 |

The Python corpus runner failed to compile, so runtime proof is also absent.

TypeScript and Rust minimized comparisons exceeded the bounded batch budget and
were stopped. They need a cheaper comparison/profile path before scope
promotion can be evaluated safely.

## Successor Tasks

1. Add an action-list comparison artifact that reports owner states, macro
   sequences, reusable/fragile/recovery flags, and sharing status for local and
   upstream rows. Use it to close or explicitly classify the JavaScript
   `parse_action_list_count=3592/3588` residual.
2. Add runtime lex minimization diagnostics for start-row ownership and merged
   runtime lex states. The next target is explaining why local emits 10 unique
   lex-mode start states and 266 total runtime lex cases while upstream emits
   16 start states and 279 cases.
3. Add bounded profile modes for TypeScript and Rust comparisons so Phase 5 can
   produce promotion decisions without unbounded wall-clock behavior.

No remaining 2026-05-01 JavaScript gap is hidden by stale goldens: each item is
either closed or carried forward here with current evidence.
