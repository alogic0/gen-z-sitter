# Milestone 13 Implementation Checklist

## Goal

Implement the next parser-generation milestone after Milestone 12:

- define the first compatibility-oriented parser output boundary
- deepen emitted parser output beyond the Milestone 12 query/helper layer
- clarify how compatibility work should be staged without prematurely claiming full upstream ABI parity

Milestone 13 is the bridge between:

- “the generator can emit a richer runtime-facing parser translation unit”

and

- “the generator has an explicit compatibility-oriented parser boundary that later ABI and behavioral work can target”.

## Runtime-Facing API Scope Decision

Milestone 13 uses this emitted API scope as its working contract:

- the emitted parser surface may expose:
  - parser-level metadata queries
  - per-state metadata queries
  - indexed access to action/goto/unresolved entries
  - field-level helpers over those entries
  - symbol-based lookup helpers
  - boolean predicate helpers
- the emitted parser surface may add:
  - higher-level state and parser convenience helpers
  - small compatibility-oriented helper functions that make the emitted API easier to consume
- the emitted parser surface must not yet imply:
  - upstream Tree-sitter runtime ABI compatibility
  - full `parser.c` parity
  - compressed/final table layout promises
  - external scanner/runtime integration

This means Milestone 13 is allowed to deepen the runtime-facing emitted API, but it is still not allowed to silently turn that API into a claimed ABI contract.

## Compatibility Layering Decision

Milestone 13 will stage compatibility work through an intermediate compatibility layer first.

That means:

- the emitted parser surface should keep getting clearer and more compatibility-oriented
- later milestones may map that surface onto upstream expectations
- the project does not yet claim direct upstream Tree-sitter C runtime ABI compatibility at the current emitted boundary

Why this is the chosen direction:

- it keeps Milestone 13 focused on making the emitted boundary explicit and testable
- it avoids prematurely freezing the current emitted API as if it were already the upstream ABI
- it gives later milestones room to add compatibility shims, naming adjustments, and structural changes without pretending the ABI problem is already solved

## What Milestone 13 Includes

- decisions about compatibility layering and emitted API scope
- fuller parser output beyond Milestone 12’s query/helper surface
- exact artifacts for the richer runtime-facing emitted parser surface
- explicit blocked-output behavior at that richer boundary
- enough structure to begin later compatibility-oriented work

## What Milestone 13 Does Not Include

- full upstream Tree-sitter runtime ABI compatibility
- full `parser.c` parity
- lexer/scanner emission
- external scanner integration
- parse-table compression/minimization

## Main Targets

### 1. Compatibility-oriented emitted API boundary

- make the emitted parser API explicit enough that later compatibility work can target it
- avoid accidental ABI promises

### 2. Richer parser output

- add another layer of parser-oriented emitted structure beyond the Milestone 12 helper/query layer

### 3. Exact richer-output artifacts

- keep ready and blocked outputs pinned by exact real-path goldens

### 4. Blocked-output policy at the richer boundary

- keep blocked behavior explicit and inspectable

## Recommended Implementation Order

1. lock the emitted API scope decision in the docs
2. deepen parser output beyond the current query/helper layer
3. update exact ready/blocked artifacts
4. decide compatibility layering direction
5. review whether the emitted parser boundary is strong enough to begin compatibility work

## Current Status

Implemented now:

- the richer runtime-facing emitted parser surface is already pinned through the existing exact parser.c-like goldens
- those exact artifacts cover:
  - one ready grammar
  - one blocked grammar
- the richer emitted surface already includes:
  - `TSRuntimeStateInfo`
  - `TSParserRuntime`
  - parser/runtime accessors
  - state and entry lookup helpers
  - predicate helpers
- Milestone 13 now also adds:
  - a compatibility-layering decision
  - a richer runtime summary/output layer beyond the Milestone 12 helper/query surface
  - explicit blocked-state helpers at the runtime-facing layer
  - symbol-based lookup and presence predicates over parser entries

This means the “exact richer-output artifacts” item is already satisfied by the current parser.c emitter path rather than needing a separate artifact format.

## Review Result

The emitted parser boundary is strong enough to begin compatibility-oriented work.

Why:

- the emitted API scope is explicit
- compatibility layering is explicit
- parser output is richer than the Milestone 12 helper/query boundary
- ready and blocked richer outputs are pinned by exact real-path goldens
- blocked behavior is explicit both in emitted data and in emitted helper/query APIs

What remains deferred beyond Milestone 13:

- direct upstream Tree-sitter C runtime ABI compatibility
- full `parser.c` parity
- lexer/scanner and external scanner work
- parse-table compression/minimization

## Exit Criteria

Milestone 13 is complete when:

- the emitted parser boundary is explicitly scoped for compatibility-oriented work
- parser output is richer than the Milestone 12 helper/query surface
- ready and blocked outputs are pinned by exact real-path goldens
- the next milestone can focus on compatibility targets rather than first deciding the emitted API scope

## Completion State

Milestone 13 is complete.

Completed in this milestone:

- emitted API scope decision before any ABI claim
- explicit compatibility-layering decision through an intermediate layer
- richer parser output beyond the Milestone 12 helper/query layer
- exact ready/blocked artifacts for the richer runtime-facing parser surface
- explicit blocked-output behavior at the richer runtime-facing layer
- a richer compatibility-oriented emitted API including:
  - parser/runtime summary structs
  - per-state runtime summaries
  - field-level entry accessors
  - symbol-based lookup
  - predicate helpers

Deferred to the next milestone:

- direct ABI compatibility work
- fuller parser output closer to upstream `parser.c`
