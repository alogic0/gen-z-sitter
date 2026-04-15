# Prepared Grammar IR

## Purpose

Define the boundary between raw grammar loading and automata/table generation.

The `PreparedGrammar` stage should:

- remove input-format quirks
- assign stable symbol identities
- preserve all semantically relevant grammar information
- become the canonical input to lexing and parse-table construction

## Why This IR Exists

The raw loaded grammar is too close to JSON/DSL shape:

- names are still unresolved strings
- ordering constraints may be implicit
- aliases and metadata are attached in source-oriented forms
- validation may still be incomplete

The prepared IR exists to make later stages simpler, deterministic, and easier to test.

## Design Principles

- all symbol references are resolved
- string names are interned once
- semantic ordering is explicit
- no renderer-specific structures
- no CLI-specific structures
- no unresolved source-schema variants

## Proposed Core Types

```zig
pub const SymbolId = enum(u32) { _ };

pub const SymbolKind = enum {
    terminal,
    non_terminal,
    external,
    auxiliary,
    anonymous,
    supertype,
};

pub const Assoc = enum {
    none,
    left,
    right,
};

pub const PrecedenceValue = union(enum) {
    none,
    integer: i32,
    named: []const u8,
};
```

## Symbol Table

The symbol table must be the single source of truth for symbol identity.

```zig
pub const SymbolInfo = struct {
    id: SymbolId,
    name: []const u8,
    kind: SymbolKind,
    named: bool,
    visible: bool,
    supertype: bool,
};
```

Rules:

- every symbol gets a stable `SymbolId`
- insertion order must be deterministic
- anonymous string tokens still receive stable IDs
- external tokens are distinguished from internal terminals
- if a name exists both as an internal rule and an external token, internal resolution wins

## Rule Model

The prepared rule model should preserve only semantic constructs.

```zig
pub const RuleId = enum(u32) { _ };

pub const Metadata = struct {
    field_name: ?[]const u8 = null,
    alias: ?Alias = null,
    precedence: PrecedenceValue = .none,
    associativity: Assoc = .none,
    dynamic_precedence: i32 = 0,
    token: bool = false,
    immediate_token: bool = false,
    reserved_context_name: ?[]const u8 = null,
};

pub const Alias = struct {
    value: []const u8,
    named: bool,
};

pub const Rule = union(enum) {
    blank,
    symbol: SymbolId,
    string: []const u8,
    pattern: RegexAtom,
    seq: []RuleId,
    choice: []RuleId,
    repeat: RuleId,
    metadata: struct {
        inner: RuleId,
        data: Metadata,
    },
};
```

Wrapper-lowering rule:

- nested `FIELD`, `ALIAS`, `PREC*`, `TOKEN`, `IMMEDIATE_TOKEN`, and `RESERVED` wrappers should be merged into one canonical metadata node where possible
- later passes should not depend on wrapper nesting depth for semantic meaning

## Variable Model

Each named grammar rule should become a prepared variable.

```zig
pub const Variable = struct {
    symbol: SymbolId,
    name: []const u8,
    rule: RuleId,
    kind: VariableKind,
};

pub const VariableKind = enum {
    named,
    anonymous,
    hidden,
    auxiliary,
};
```

## Prepared Grammar Root

```zig
pub const PreparedGrammar = struct {
    grammar_name: []const u8,
    variables: []Variable,
    external_tokens: []Variable,
    rules: []Rule,
    symbols: []SymbolInfo,
    extra_rules: []RuleId,
    expected_conflicts: []ConflictSet,
    precedence_orderings: []PrecedenceOrdering,
    variables_to_inline: []SymbolId,
    supertype_symbols: []SymbolId,
    reserved_word_sets: []ReservedWordSet,
    word_token: ?SymbolId,
};
```

## Conflict Set

```zig
pub const ConflictSet = struct {
    members: []SymbolId,
};
```

Rules:

- members must be sorted by stable symbol order
- duplicate members removed
- duplicate sets removed

## Precedence Ordering

```zig
pub const PrecedenceOrdering = struct {
    groups: [][]const []const u8,
};
```

Alternative:

Convert names to canonical IDs earlier if named precedences are interned.

Current upstream-aligned rule:

- named precedences used by `PREC`, `PREC_LEFT`, and `PREC_RIGHT` must already have been declared in one of the precedence ordering entries before later passes begin

## Reserved Words

If the generator needs reserved word support from the source grammar, represent it explicitly:

```zig
pub const ReservedWordSet = struct {
    context_name: []const u8,
    words: []RuleId,
};
```

This remains rule-based at the prepared-IR boundary in the current Zig implementation, matching the fact that reserved words are still lowered before token extraction.

## Invariants

The following invariants must hold before lex/parse-table stages begin:

- all symbol references resolve to valid `SymbolId`
- all variable rules point to valid `RuleId`
- no duplicate symbol names within the same semantic class where forbidden
- all retained inline targets exist and refer to valid variables
- all supertype targets exist and refer to valid variables
- all conflict sets contain at least two members
- `word_token`, if present, refers to a terminal-compatible symbol
- missing `inline` names have already been ignored and removed
- supertype targets have already forced the corresponding variables to hidden
- named precedence references are declared

## Preparation Passes

Recommended pass order:

1. decode raw grammar
2. intern symbol names
3. assign initial symbol kinds
4. resolve rule references
5. normalize metadata wrappers into canonical merged metadata nodes
6. flatten nested choices/sequences where appropriate
7. expand repeats into auxiliary forms
8. extract tokens and external token info
9. compute inline/supertype/default alias data
10. validate invariants

Each pass should consume one structure and return a stricter one when practical.

## What Must Not Be In This IR

- NFA states
- parse-table states
- rendered C snippets
- file paths
- CLI flags
- reporting/output formatting concerns

## Serialization for Debugging

Even if this IR is optimized for compilation, it should support debug dumping in a stable form:

- stable ordering
- no raw pointer output
- readable symbol and rule IDs

Suggested debug outputs:

- symbol table dump
- resolved variables dump
- normalized rule tree dump
- inline/conflict/supertype summary dump

## Testing Strategy for Prepared IR

Test this IR before parser generation exists.

### Unit tests

- symbol interning
- duplicate rejection
- metadata normalization
- repeat expansion
- inline target resolution
- internal-over-external name resolution
- undeclared named precedence rejection

### Snapshot tests

For curated grammars, dump:

- symbols
- variables
- normalized rules

Compare against golden files.

### Differential tests

For selected grammars, compare prepared IR summaries against the Rust generator's analogous intermediate information where available.

## Immediate Implementation Scope

The first version of this IR should support:

- simple named rules
- sequences
- choices
- string tokens
- metadata wrappers
- extras
- externals
- inline
- supertypes
- expected conflicts

Defer deeper optimizations until the IR is stable.
