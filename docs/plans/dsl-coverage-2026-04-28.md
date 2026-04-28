# Grammar DSL Coverage Matrix — 2026-04-28

This matrix records the current local grammar DSL boundary for Phase 2 of
`tree-sitter-gap-reduction-2026-04-28.md`. It is based on the local raw grammar
model, JSON loader, `grammar.js` loader, and existing focused tests.

## Loader Boundary

- `grammar.json`: supported as the primary structured input.
- `grammar.js`: supported when the module exports an already-resolved grammar
  JSON object. The loader runs the selected JavaScript runtime and serializes
  the exported value.
- Upstream `dsl.js` execution semantics: not yet reproduced locally. The current
  loader does not inject Tree-sitter DSL globals into arbitrary grammar source.

## Top-Level Grammar Fields

| Construct | Status | Notes |
| --- | --- | --- |
| `name` | supported | Required by local JSON loader. |
| `version` | supported | Preserved into generated metadata. |
| `rules` | supported | Parsed into local raw rule entries. |
| `precedences` | supported | Validated and lowered into precedence orderings. |
| `conflicts` | supported | Loaded as expected conflicts and checked for unused declarations. |
| `externals` | supported | Loaded and carried through scanner metadata; runtime support is staged. |
| `extras` | supported | Extracted into lexical extras and parser metadata. |
| `inline` | supported | Local inlining exists; external inline symbols are rejected. |
| `supertypes` | supported | Preserved into node-types and generated metadata. |
| `word` | supported with validation | Must lower to an internal lexical terminal. |
| `reserved` | supported | Reserved word sets are loaded and emitted. |

## Rule Constructs

| Construct | Status | Notes |
| --- | --- | --- |
| `blank` | supported | Raw `BLANK`. |
| string literals | supported | Raw `STRING`, extracted into lexical terminals. |
| regex/pattern | partially supported | Raw `PATTERN` loads; regex feature parity remains Phase 4 work. |
| `symbol` | supported | Undefined symbols are rejected. |
| `choice` | supported | Raw `CHOICE`. |
| `seq` | supported | Raw `SEQ`. |
| `repeat` | supported with known parity risk | Auxiliary naming/dedup differs from upstream in some cases. |
| `repeat1` | supported with known parity risk | Same auxiliary-expansion risk as `repeat`. |
| `field` | supported | Field metadata is emitted; inherited field metadata is not fully modeled. |
| `alias` | supported | Alias rows are emitted; exact upstream symbol ordering can still differ. |
| `prec` | supported | Static precedence is parsed and used in conflict resolution. |
| `prec.left` | supported | Associativity is parsed and used in conflict resolution. |
| `prec.right` | supported | Associativity is parsed and used in conflict resolution. |
| `prec.dynamic` | supported | Dynamic precedence is preserved into parse actions and runtime choices. |
| `token` | supported | Tokenized rules are extracted into lexical grammar. |
| `token.immediate` | supported structurally | Immediate-token runtime parity remains tied to lexer/table parity. |
| `reserved` rule wrapper | supported | Parsed as raw `RESERVED` and carried through reserved-word contexts. |

## Known Phase 2 Gaps

- Arbitrary upstream-style `grammar.js` source that depends on DSL globals is
  not locally evaluated. The current loader expects an exported JSON-shaped
  grammar object.
- Upstream does not provide a normalized `grammar.json` artifact for the JSON
  snapshot through `tree-sitter generate --no-parser`, so raw-grammar
  differential output needs a separate oracle strategy.
- `repeat` and `repeat1` are supported, but the current comparison report shows
  large symbol/state-count differences on JSON and Ziggy. Auxiliary expansion
  and dedup are still likely Phase 2/3 gap sources.
- Regex syntax loads as patterns, but complete Tree-sitter regex feature parity
  is deferred to Phase 4.
- `node-types.json` is now compared by hash in `compare-upstream`, and JSON
  currently differs from upstream. The concrete field/child diff should be the
  next Phase 2.3 slice.
