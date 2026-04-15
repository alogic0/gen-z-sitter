# Milestone 15 Implementation Checklist

Milestone 15 closes the first parser/runtime compatibility boundary.

It is the milestone where the project stops saying only “the emitter is runtime-facing” and starts saying “the emitted parser surface has a concrete compatibility contract that later behavioral and ABI work can target.”

## Goals

- define the first concrete compatibility target against upstream generated parser behavior
- centralize ABI/version handling instead of scattering it across emitters or tests
- validate the emitted parser surface structurally, not just by incidental golden text
- close the most important contract-level gaps before moving on to behavioral equivalence work

## What Milestone 15 Includes

- a centralized compatibility module for parser/runtime-facing emission
- explicit emitted compatibility metadata in the `parser_c` output
- structural compatibility checks for the emitted parser surface
- a deterministic emitted symbol-table contract and symbol accessors
- exact ready and blocked parser-output artifacts updated to the new compatibility boundary

## What Milestone 15 Does Not Include

- direct upstream Tree-sitter C runtime ABI compatibility
- full `parser.c` parity
- external scanner/runtime integration
- corpus-level parser behavior equivalence
- parse-tree behavioral comparison against upstream generated parsers

## Implemented

- `src/parser_emit/compat.zig`
  - defines the first concrete compatibility target:
    - target: `tree-sitter-runtime-surface`
    - layer: `intermediate`
  - centralizes:
    - `TS_LANGUAGE_VERSION`
    - `TS_MIN_COMPATIBLE_LANGUAGE_VERSION`
- `src/parser_emit/parser_c.zig`
  - emits explicit compatibility metadata:
    - `TSCompatibilityInfo`
    - parser compatibility accessors
  - emits a deterministic symbol-table contract:
    - `TSSymbolInfo`
    - `TS_SYMBOL_COUNT`
    - symbol metadata accessors and lookup helpers
- `src/parser_emit/compat_checks.zig`
  - validates the emitted compatibility surface structurally
  - checks for:
    - compatibility/version metadata
    - compatibility accessors
    - runtime accessor presence
    - symbol-table surface
- `src/parse_table/pipeline.zig`
  - parser.c-like emitter goldens for both ready and blocked grammars now also pass the compatibility-surface checks

## Deferred Compatibility Mismatches

The following are still intentionally deferred beyond Milestone 15:

- direct upstream Tree-sitter C runtime ABI compatibility
- full `TSLanguage` / runtime object parity
- external scanner compatibility
- lexer/runtime integration details
- parse-tree and failure-behavior equivalence on shared corpora
- compression/minimization and final table-layout parity

## Exit Criteria

Milestone 15 is complete when:

- the emitted parser surface exposes centralized compatibility/version metadata
- the emitted parser surface exposes a deterministic symbol-table contract
- structural compatibility checks pass for both ready and blocked emitted parsers
- the remaining compatibility gaps are explicitly documented as deferred rather than accidental
- the next milestone can focus on behavioral equivalence work instead of first inventing the runtime contract

## Completion State

Milestone 15 is complete.

Delivered in this milestone:

- first explicit compatibility target and layering boundary
- centralized ABI/version handling
- parser-output structure checks for runtime-facing compatibility expectations
- deterministic emitted symbol-table contract and symbol accessors
- updated exact ready and blocked parser-output artifacts at the stronger compatibility boundary

Deferred to Milestone 16+:

- corpus-driven behavioral equivalence
- compiled-parser comparison against upstream output
- deeper ABI/runtime compatibility work
