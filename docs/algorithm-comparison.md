# Algorithm Comparison: gen-z-sitter vs tree-sitter

## What Both Share

Both implement **LR(1) parse table generation** with the same general shape:
- FIRST set computation (fixpoint loop)
- Canonical item set closure
- Shift/reduce and reduce/reduce conflict detection
- Precedence + associativity-based conflict resolution
- Separate lexical and syntax grammars

---

## Key Algorithmic Differences

### 1. Runtime Parsing Algorithm

|                   | gen-z-sitter                                    | tree-sitter                                            |
|-------------------|-------------------------------------------------|--------------------------------------------------------|
| **Parser type**   | Generates tables only (no runtime yet)          | Full **GLR** runtime in C                              |
| **Ambiguity**     | Resolved statically at table generation time    | Handled dynamically: creates multiple **stack versions** at parse time |
| **Stack**         | N/A                                             | Multi-headed stack, up to 6 concurrent versions        |

Tree-sitter's GLR runtime is the biggest difference: when a state has both shift and reduce actions on the same token, it **forks the parse** into multiple concurrent versions and prunes losers later. gen-z-sitter has no runtime yet — it only generates the tables.

### 2. Error Recovery

Tree-sitter has a sophisticated two-stage error recovery baked into the runtime:
1. **Look back** through previous stack states to find one where the bad token is valid
2. **Skip the bad token** and wrap skipped content in an `ERROR` node
3. Cost function: `error_cost + depth × penalty + bytes_skipped × penalty`

gen-z-sitter: no error recovery — the generator handles table construction only, and unresolvable conflicts produce a diagnostic rather than a fallback strategy.

### 3. State Minimization

|                        | gen-z-sitter                                                                    | tree-sitter                                           |
|------------------------|---------------------------------------------------------------------------------|-------------------------------------------------------|
| **DFA minimization**   | `minimize.zig` — partition states into equivalence classes, iteratively refine  | Not present in generator                              |
| **Table compaction**   | Not present                                                                     | `small_parse_table` — compact encoding for sparse states |

gen-z-sitter uses optional **Hopcroft-style DFA minimization** post-construction (`minimize_states: bool`). Tree-sitter instead uses a compact small-table encoding for states with few actions.

### 4. Incremental Parsing

Tree-sitter's central innovation: **reuses subtrees from previous parses** when only part of the file changed.
- `ts_parser__reuse_node`: if the old tree's node matches current state + position, skip re-parsing it entirely
- Supports `included_ranges` to limit work to changed regions

gen-z-sitter has no incremental parsing — it is a table generator, not a runtime.

### 5. Item and Lookahead Representation

|                       | gen-z-sitter                                                  | tree-sitter                                                             |
|-----------------------|---------------------------------------------------------------|-------------------------------------------------------------------------|
| **ParseItem**         | `(production_id: u32, step_index: u16)` — minimal            | `(variable_index, production, step_index, has_preceding_inherited_fields)` — also tracks field inheritance |
| **Lookaheads**        | Parallel `[]bool` arrays (terminals + externals)              | Bitset-style sets in Rust                                               |
| **Context follow**    | Explicit context follow sets for nullable suffix propagation  | Part of standard FIRST/closure logic                                    |

Tree-sitter's items carry `has_preceding_inherited_fields` for tracking AST field inheritance through nullable chains — needed for `node-types.json` metadata output. gen-z-sitter's items are leaner.

### 6. Conflict Resolution Pipeline

Both use precedence → associativity → expected-conflict whitelist. The structural difference:

- **gen-z-sitter** uses a clean **two-phase** design (`resolution.zig`): first collect all candidate actions, then resolve them separately. The `ResolvedDecision` type distinguishes `reduce_reduce_expected` (diagnostic only) from `reduce_reduce_deferred` (blocking).
- **tree-sitter** interleaves conflict detection and resolution during table construction (`handle_conflict` modifies state actions in-place) — faster but harder to audit independently.

### 7. Lexer / Scanner

|                        | gen-z-sitter                              | tree-sitter                                              |
|------------------------|-------------------------------------------|----------------------------------------------------------|
| **Lexer generation**   | Token extraction done; NFA→DFA in progress | Full **NFA → DFA** conversion; generates a C lex function |
| **External scanners**  | Supported in grammar IR                   | Supported via a custom C scanner API                     |
| **Reserved words**     | Not yet                                   | `reserved_word_set_id` per production step               |

---

## Summary

gen-z-sitter is a **Zig reimplementation of tree-sitter's Rust generator**, with three notable additions:

1. **DFA minimization** (`minimize.zig`) — not present in tree-sitter's generator
2. **Two-phase conflict resolution** — candidates collected first, then resolved separately
3. **Explicit context follow sets** for nullable suffix lookahead propagation

And it omits (not yet implemented) what makes tree-sitter distinctive at runtime:
- **GLR multi-version parse stack**
- **Incremental parsing / subtree reuse**
- **Two-stage error recovery with cost-based pruning**

The table generation algorithm is fundamentally the same LR(1) canonical construction — the divergence is almost entirely in the runtime execution model.
