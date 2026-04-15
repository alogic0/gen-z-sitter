# Milestone 1 Implementation Checklist

## Goal

Implement the first real generator functionality in Zig:

- load `grammar.json`
- validate its base shape
- produce structured diagnostics
- wire the `generate` command through a real grammar-loading path

Milestone 1 does not include:

- `grammar.js` execution
- normalization passes
- prepared IR
- lexical generation
- parse-table generation
- `node-types.json`
- `parser.c`

## Upstream Reference Points

This milestone should track the current Tree-sitter generator behavior primarily from:

- `load_grammar_file` in `/home/alogic0/prog/tree-sitter/crates/generate/src/generate.rs`
- `load_js_grammar_file` in `/home/alogic0/prog/tree-sitter/crates/generate/src/generate.rs`
- `GrammarJSON` and `RuleJSON` in `/home/alogic0/prog/tree-sitter/crates/generate/src/parse_grammar.rs`

For Milestone 1, only the `grammar.json` path is required. `grammar.js` remains deferred.

## Deliverables

By the end of Milestone 1, this project should have:

- `src/grammar/raw_grammar.zig`
- `src/grammar/json_loader.zig`
- `src/grammar/validate.zig`
- `src/grammar/loader.zig`
- updated `src/cli/command_generate.zig`
- expanded fixture and validation tests

Optional in Milestone 1, but useful if time permits:

- `src/grammar/parse_grammar.zig` as a placeholder facade for later phases
- a minimal grammar summary printer for debug output

## File-by-File Plan

### 1. `src/grammar/raw_grammar.zig`

Purpose:

- define the raw schema-level types for `grammar.json`
- keep this close to the upstream `GrammarJSON` and `RuleJSON` shape

Implement:

- `RawGrammar`
- `RawRule`
- `RawPrecedenceValue`
- helper enums/unions for tagged rules

Minimum fields to support now:

- `name`
- `rules`
- `precedences`
- `conflicts`
- `externals`
- `extras`
- `inline`
- `supertypes`
- `word`
- `reserved`

Suggested shape:

```zig
pub const RawGrammar = struct {
    name: []const u8,
    rules: std.StringArrayHashMapUnmanaged(RawRule),
    precedences: []const []const RawRule,
    conflicts: []const []const []const u8,
    externals: []const RawRule,
    extras: []const RawRule,
    inline: []const []const u8,
    supertypes: []const []const u8,
    word: ?[]const u8,
    reserved: std.StringArrayHashMapUnmanaged(RawReservedSet),
};
```

Raw rule variants to support:

- `ALIAS`
- `BLANK`
- `STRING`
- `PATTERN`
- `SYMBOL`
- `CHOICE`
- `FIELD`
- `SEQ`
- `REPEAT`
- `REPEAT1`
- `PREC_DYNAMIC`
- `PREC_LEFT`
- `PREC_RIGHT`
- `PREC`
- `TOKEN`
- `IMMEDIATE_TOKEN`
- `RESERVED`

Acceptance criteria:

- all raw types compile
- rules can represent the current upstream grammar JSON schema

### 2. `src/grammar/json_loader.zig`

Purpose:

- read a `.json` grammar file from disk
- parse it into `RawGrammar`
- map I/O and parse failures into structured diagnostics

Implement:

- `loadGrammarJson(allocator, path) !RawGrammar`
- file-extension gate for `.json`
- parsing through `std.json`

Rules:

- do not support `grammar.js` here
- reject directories
- return structured load/parse errors rather than plain strings

Checklist:

- read file contents
- parse JSON into a temporary dynamic or direct typed representation
- lower parsed JSON into `RawGrammar`
- free temporary JSON parser state correctly

Acceptance criteria:

- valid `grammar.json` loads
- malformed JSON returns a structured parse diagnostic
- directory path is rejected
- non-`.json` path is rejected by this loader

### 3. `src/grammar/validate.zig`

Purpose:

- perform Milestone 1 schema/base-shape validation only

This is not semantic grammar normalization yet.

Implement validation checks for:

- `name` exists and is non-empty
- `rules` exists and is non-empty
- `rules` values decode as valid `RawRule`
- `extras` cannot contain empty strings
- `precedences` may contain only string and symbol entries
- `reserved` entries must be arrays

These checks are directly grounded in the current upstream behavior visible in `parse_grammar.rs`.

Recommended API:

```zig
pub fn validateRawGrammar(g: *const RawGrammar) !void
```

Acceptance criteria:

- invalid extras are rejected
- invalid precedence entries are rejected
- invalid reserved-word set shape is rejected
- diagnostics name the failing subsystem and, when possible, the relevant field

### 4. `src/grammar/loader.zig`

Purpose:

- provide the top-level Milestone 1 grammar loading entry point for the CLI

Implement:

- extension dispatch
- `grammar.json` path now
- placeholder error for `.js`

Suggested API:

```zig
pub const LoadedGrammar = union(enum) {
    raw_json: RawGrammar,
};

pub fn loadGrammarFile(allocator: std.mem.Allocator, path: []const u8) !LoadedGrammar
```

Behavior:

- `.json` -> load and validate
- `.js` -> return a deferred/unimplemented diagnostic for now
- any other extension -> invalid path/extension diagnostic

Acceptance criteria:

- CLI can call one loader function regardless of extension
- `.js` fails clearly but intentionally

### 5. `src/cli/command_generate.zig`

Purpose:

- replace the current placeholder-only path with a real Milestone 1 loader path

Change behavior from:

- always print scaffold message and return `NotImplemented`

to:

- call `grammar/loader.zig`
- for `.json`, load and validate successfully
- print a short success summary
- still stop before normalization/generation

Suggested success output:

- grammar name
- number of rules
- number of externals
- number of extras

Example behavior:

- `generate path/to/grammar.json` prints a success/info summary and exits `0`
- `generate path/to/grammar.js` prints an explicit deferred/unimplemented diagnostic and exits nonzero

Acceptance criteria:

- `zig build run -- generate path/to/valid/grammar.json` exits successfully
- invalid grammar path or invalid JSON exits with structured diagnostics

### 6. `src/tests/fixtures.zig`

Purpose:

- add Milestone 1 fixture helpers and embedded sample grammars

Add fixtures for:

- minimal valid grammar
- malformed JSON
- invalid `extras`
- invalid `precedences`
- invalid `reserved`
- unsupported `.js` path behavior at loader level

Acceptance criteria:

- tests can load fixture content without filesystem dependence where practical

### 7. `src/tests/golden.zig`

Purpose:

- support small textual assertions for diagnostics or summaries

For Milestone 1, keep it simple:

- `expectContains`
- optional `expectNotContains`

### 8. `src/grammar/parse_grammar.zig` (optional placeholder)

Purpose:

- reserve the eventual next boundary

Milestone 1 implementation can leave this as:

- a file with a TODO API definition
- no real lowering yet

This is optional if it adds noise.

## Recommended Implementation Order

Implement in this order:

1. `src/grammar/raw_grammar.zig`
2. `src/grammar/json_loader.zig`
3. `src/grammar/validate.zig`
4. `src/grammar/loader.zig`
5. update `src/cli/command_generate.zig`
6. expand `src/tests/fixtures.zig`
7. add Milestone 1 tests

This order keeps the loader path testable before the CLI changes land.

## Detailed Task Checklist

### Task Group A: Create grammar module skeleton

- create `src/grammar/`
- add `raw_grammar.zig`
- add `json_loader.zig`
- add `validate.zig`
- add `loader.zig`
- import them from `src/main.zig` test block

Done when:

- the new files compile

### Task Group B: Define raw schema model

- encode all `RuleJSON` variants from upstream
- encode precedence value union
- encode top-level `RawGrammar`
- document which invariants are deferred to later milestones

Done when:

- a valid JSON grammar can be represented without loss at the raw layer

### Task Group C: Implement JSON decoding

- read `grammar.json`
- parse JSON
- decode top-level fields
- decode recursive rule shapes
- allocate all dynamic arrays/slices from the provided allocator

Done when:

- unit tests can load a minimal valid grammar

### Task Group D: Implement validation

- enforce non-empty grammar name
- enforce non-empty rules set
- reject empty-string `extras`
- reject invalid precedence entries
- reject non-array `reserved` entries

Done when:

- negative tests pass

### Task Group E: Wire CLI success path

- call `loadGrammarFile`
- if `.json` succeeds, print a short summary
- if `.js` is passed, print deferred/unimplemented diagnostic
- preserve existing CLI argument contract

Done when:

- `generate` with a valid `.json` exits `0`

### Task Group F: Add tests

- unit tests for rule decoding
- unit tests for validation
- CLI-level tests where practical
- fixture coverage for both valid and invalid inputs

Done when:

- `zig build test` covers all Milestone 1 validation paths

## Test Matrix

### Positive tests

1. minimal valid grammar
2. valid grammar with `extras`
3. valid grammar with `externals`
4. valid grammar with `precedences`
5. valid grammar with `reserved`

### Negative tests

1. malformed JSON
2. missing `name`
3. empty `name`
4. missing `rules`
5. empty `rules`
6. empty string in `extras`
7. invalid precedence member
8. invalid `reserved` shape
9. `.js` path returns deferred/unimplemented
10. unknown extension is rejected

## Success Summary Format

Milestone 1 does not need rich output, but it should prove the loader is real.

Recommended summary text:

```text
info: loaded grammar.json successfully
note: grammar: javascript
note: rules: 123
note: externals: 2
note: extras: 1
```

This can change later, but keep it deterministic and easy to test.

## Exit Criteria

Milestone 1 is complete when all of the following are true:

- `src/grammar/raw_grammar.zig` exists and models the upstream JSON grammar schema
- `src/grammar/json_loader.zig` can load and decode valid `grammar.json`
- `src/grammar/validate.zig` enforces the base schema checks listed above
- `src/grammar/loader.zig` dispatches by extension
- `generate <path/to/grammar.json>` succeeds and prints a summary
- `generate <path/to/grammar.js>` fails explicitly as deferred
- `zig build`
- `zig build test`

## Explicitly Deferred to Milestone 2+

- semantic variable usage analysis
- prepared grammar lowering
- symbol interning
- normalization passes
- repeat expansion
- alias lowering
- inline/supertype resolution
- lexical extraction
- node-types generation
- parser rendering

## Immediate Next Command Sequence

After this checklist is accepted, the implementation work should start with:

1. create `src/grammar/raw_grammar.zig`
2. create `src/grammar/json_loader.zig`
3. add one passing test for a minimal valid grammar
4. add one failing test for invalid `extras`
5. wire `command_generate.zig` to call the loader

That is the shortest path from scaffold to real functionality.
