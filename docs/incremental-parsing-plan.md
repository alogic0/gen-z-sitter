# Incremental Parsing — Scoping Plan (M46 T6)

This document scopes the work needed to support incremental parsing in
gen-z-sitter. It does not implement anything; implementation is M47+.

---

## What Incremental Parsing Requires

Tree-sitter's incremental parsing rests on one core invariant: if an old
subtree's byte range does not overlap the edit region, and the parser arrives
at the same state it was in when that subtree was first parsed, the subtree
can be reused without re-parsing its contents.

Three things must exist to exploit this:

1. **A concrete syntax tree** — nodes with byte ranges (`start_byte`,
   `end_byte`) and a production identity (what rule reduced to this node).
2. **Per-node reuse markers** — enough information to decide "same parse state
   + same byte range ⟹ same result".
3. **An old-tree input to the parser** — the previous `TSTree` is threaded into
   `ts_parser_parse` alongside the new source; the advance loop checks
   `ts_parser__reuse_node` before lexing.

---

## Current State of gen-z-sitter

### What exists

| Component | Status |
|---|---|
| Parse tables (LR states, actions, gotos) | Complete |
| GLR behavioral harness (`harness.zig`) | Complete — tracks `consumed_bytes`, `shifted_tokens`, `error_count` |
| Lexer state tables | Complete (M44) |
| Conflict resolution | Complete (M45) |
| Alias sequences | Complete (M46 T5) |

### What does not exist

| Component | Gap |
|---|---|
| **Syntax tree node type** | No `ParseNode` / `TSTree` — `SimulationResult` is scalar only |
| **Byte ranges on nodes** | Not tracked; the harness only advances a cursor |
| **Production identity on nodes** | Not stored; reductions only update the GLR stack |
| **Tree builder in the harness** | The GLR loop shifts tokens but builds no tree |
| **Old-tree parameter** | No API surface for a previous parse result |
| **Reuse fast path** | No `ts_parser__reuse_node` equivalent |

---

## Prerequisite: Tree Construction (M47)

Incremental parsing cannot begin until there is a concrete tree to reuse.
The minimum tree representation needed:

```zig
pub const ParseNode = struct {
    production_id: u32,          // which rule reduced to this node
    start_byte: u32,
    end_byte: u32,
    children: []ParseNode,       // owned slice; empty for terminals
    is_error: bool,
};
```

The GLR harness reduce path must build `ParseNode` values and push them onto
the version's value stack in parallel with the state stack. This is the
blocking M47 item before incremental work can start.

---

## Required Table Metadata Changes

The generated `parser.c` tables need no new fields for a minimal incremental
proof-of-concept. The reuse decision is made at runtime using:

- the current parse state ID (already in `TSParser.states`)
- the node's `start_byte` / `end_byte` (stored on `ParseNode`, not in tables)
- the production ID (stored on `ParseNode`)

One table change that *will* matter at scale: **`has_external_tokens` per
state** — if a state invokes the external scanner, its subtrees cannot be
naively reused because the external scanner has side effects. Tree-sitter
tracks this in `TSStateId external_lex_state`. We should add
`external_lex_state: u16` to `TSRuntimeStateInfo` (currently emitted as
`TSRuntimeStateInfo` in `parser_c.zig`) before the first incremental
proof-of-concept.

---

## Minimum Viable Proof-of-Concept Plan

**Goal**: reparse a file after a single-character insertion at the end, reusing
all unchanged nodes from the previous parse.

### Step 1 — Tree builder in the harness (M47 blocker)

- Add `ParseNode` type to `src/behavioral/`.
- In `simulatePreparedScannerFree`, maintain a parallel value stack next to the
  state stack inside each `ParseVersion`.
- On shift: push a terminal `ParseNode { start_byte=cursor, end_byte=cursor+len }`.
- On reduce: pop N children, create a parent `ParseNode` with the production's
  `start_byte = children[0].start_byte`, `end_byte = children[N-1].end_byte`.
- On accept: the `SimulationResult.accepted` payload gains a `tree: ParseNode`
  field alongside the existing scalars.

### Step 2 — Edit representation

```zig
pub const Edit = struct {
    start_byte: u32,
    old_end_byte: u32,
    new_end_byte: u32,
};
```

Pass `old_tree: ?ParseNode` and `edit: Edit` to a new `simulateIncremental`
entry point.

### Step 3 — Reuse check in the advance loop

Before lexing at position `cursor`, check:

```
if old_tree has a child node N such that:
    N.start_byte == cursor
    AND N.start_byte >= edit.new_end_byte  (node starts after the edit)
    AND parse_state == state_when_N_was_first_reduced
then:
    reuse N — advance cursor to N.end_byte, push N's reduction
```

The "state when N was first reduced" must be stored on `ParseNode` (add
`entry_state: u32` to the struct).

### Step 4 — `external_lex_state` guard

Skip reuse for any node whose `entry_state` has `external_lex_state != 0`.
This requires `external_lex_state` in `TSRuntimeStateInfo` (see table metadata
section above).

### Step 5 — Test

```
grammar:  source_file → number ("+" number)*
input 1:  "1+2+3"         → parse, store tree
edit:     append "+4"     → new input "1+2+3+4"
input 2:  "1+2+3+4"       → incremental parse
expected: nodes for "1", "+", "2", "+", "3" are reused; only "+4" is new
```

---

## What This Does Not Cover

- **Included ranges** (`ts_set_included_ranges`) — multi-language embedding;
  out of scope until basic incremental works.
- **External scanner state snapshotting** — the external scanner can have
  internal state that must be rewound on reuse; not needed for the
  proof-of-concept if we skip reuse for external-scanner states.
- **Dynamic precedence interaction** — GLR version pruning during incremental
  reparse may differ from a fresh parse; treat as a known gap, add a test.
- **Full `TSTree` ABI compatibility** — the `ParseNode` above is internal to
  the harness. Matching tree-sitter's public `TSTree` / `TSNode` ABI is a
  separate M47+ task.

---

## Tracked Stubs for M47

- [ ] `ParseNode` type in `src/behavioral/`
- [ ] Value stack in `ParseVersion`
- [ ] `SimulationResult.accepted.tree: ParseNode`
- [ ] `external_lex_state: u16` in `TSRuntimeStateInfo` (table change)
- [ ] `simulateIncremental` entry point
- [ ] Reuse fast path in the advance loop
- [ ] Incremental test: single append edit reuses unchanged prefix
