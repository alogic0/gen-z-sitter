# Milestone 0 Task List

## Goal

Create the project skeleton and the minimum infrastructure required to begin implementing `tree-sitter generate` in Zig.

Milestone 0 is complete when:

- the Zig project builds
- tests run
- a `generate` command exists
- diagnostics and option parsing are wired
- no generator semantics are implemented yet

## Deliverables

- `build.zig`
- `build.zig.zon`
- executable entry point
- `generate` subcommand skeleton
- diagnostics abstraction
- basic filesystem/process helpers
- test harness scaffold
- initial docs linked from a README or index

## Directory Skeleton

Create:

```text
zig_tree_sit/
  build.zig
  build.zig.zon
  README.md
  docs/
  src/
    main.zig
    cli/
    support/
    grammar/
    ir/
    lex/
    parse_table/
    node_types/
    render/
    report/
    compat/
    tests/
```

## Task List

### 1. Project bootstrap

- create `build.zig`
- create `build.zig.zon`
- define executable target
- define `zig build test`

### 2. Entry point

- add `src/main.zig`
- implement top-level exit code handling
- add placeholder command dispatch

### 3. CLI argument parsing

- add `src/cli/args.zig`
- define `GenerateOptions`
- parse:
  - grammar path
  - output dir
  - ABI version
  - `--no-parser`
  - `--json-summary`
  - `--report-states-for-rule`
  - `--js-runtime`
- validate required arguments

### 4. Diagnostics

- add `src/support/diag.zig`
- define diagnostic kind enum
- define printable diagnostic structure
- implement stderr rendering
- support path and optional rule context

### 5. Support utilities

- add `src/support/fs.zig`
- add `src/support/process.zig`
- add `src/support/json.zig`
- add `src/support/strings.zig`

Initial scope:

- file read/write
- directory creation
- path helpers
- subprocess execution wrapper
- JSON pretty print wrapper

### 6. Generate command skeleton

- add `src/cli/command_generate.zig`
- wire options to a no-op pipeline function
- print a placeholder message or structured "not implemented" diagnostic

### 7. Test scaffolding

- add `src/tests/fixtures.zig`
- add `src/tests/golden.zig`
- add a first smoke test:
  - binary parses args
  - missing grammar path fails cleanly

### 8. Documentation index

- add a small `README.md`
- link:
  - architecture doc
  - compatibility matrix
  - prepared grammar IR
  - parse-table algorithm plan
  - test strategy

## Suggested File Creation Order

1. `build.zig`
2. `build.zig.zon`
3. `src/main.zig`
4. `src/cli/args.zig`
5. `src/support/diag.zig`
6. `src/cli/command_generate.zig`
7. `src/tests/fixtures.zig`
8. `README.md`

## Coding Rules for Milestone 0

- keep everything ASCII
- no global mutable state unless strictly necessary
- avoid allocator ownership ambiguity
- prefer explicit result/error types
- do not implement grammar semantics yet
- do not add `grammar.js` subprocess support yet

## Acceptance Checklist

- `zig build` succeeds
- `zig build test` succeeds
- `zig build run -- generate` prints a useful error or placeholder diagnostic
- invalid CLI combinations fail predictably
- docs are present and readable

## Explicitly Deferred

- raw grammar schema
- `grammar.json` parsing
- prepared IR
- lexical automata
- parse tables
- `node-types.json`
- `parser.c` rendering
- `grammar.js` loading

## Risks in Milestone 0

### Over-design

Risk:

- spending too long on abstractions before any loader exists

Mitigation:

- only add infrastructure required by Milestone 1

### Premature fidelity work

Risk:

- trying to match Rust diagnostics or command behavior exactly before the pipeline exists

Mitigation:

- preserve option names and basic contract only

## Exit Recommendation

When Milestone 0 is complete, begin Milestone 1 immediately:

- implement `RawGrammar`
- parse `grammar.json`
- validate base schema
- emit structured diagnostics
