# HOWTO: Build and Use `gen-z-sitter`

`gen-z-sitter` is a Zig implementation of a Tree-sitter generator pipeline. It
loads Tree-sitter-style grammars, prepares grammar IR, builds lexer and parser
tables, emits `node-types.json`, and can emit experimental `parser.c` output.

The project is useful today for grammar inspection, parser-table diagnostics,
bounded compatibility proofs, generated `node-types.json`, and experimental
generated parser C. It is not yet a drop-in replacement for upstream
`tree-sitter generate`.

## Requirements

- Zig 0.16.x
- `node` on `PATH` when loading `grammar.js`
- A C compiler available through `zig cc` for runtime-link and compile-smoke
  checks

## Build the Command Line Tool

From the repository root:

```bash
zig build
```

Zig uses two relevant output locations:

- `.zig-cache/` stores build intermediates and compiled artifacts used by build
  steps.
- `zig-out/` is the default install prefix for the command line binary.

`zig build` compiles `gen-z-sitter` through Zig's build cache and copies the
installed binary into:

```bash
./zig-out/bin/gen-z-sitter
```

Run the installed binary directly when you want the same workflow a user or
script would use after installation:

```bash
./zig-out/bin/gen-z-sitter help
./zig-out/bin/gen-z-sitter generate path/to/grammar.json
```

Run the CLI through Zig when you are developing the project and want Zig to
compile and execute the current build artifact in one command:

```bash
zig build run -- help
zig build run -- generate path/to/grammar.json
```

`zig build run` runs the freshly rebuilt artifact from `.zig-cache/`, not the
installed file under `zig-out/bin/`. Practically, both commands run the same
program for the same build options, but they exercise different paths:

- Use `zig build run -- ...` while iterating on source changes.
- Use `./zig-out/bin/gen-z-sitter ...` to test or use the installed binary.

## Install Somewhere Else

Use `zig build install -p` to install into another directory. The executable is
placed under that directory's `bin/` folder:

```bash
zig build install -p /tmp/gen-z-sitter-install
/tmp/gen-z-sitter-install/bin/gen-z-sitter help
```

The generated CLI binary is self-contained for this project. It does not need
supplemental project data files next to it. Runtime notes:

- `grammar.js` loading still needs the JavaScript runtime you select with
  `--js-runtime`, usually `node`, available on `PATH`.
- Commands that compile or link generated C still need the local C/compiler and
  compatibility inputs used by those workflows.
- Normal grammar loading, `node-types.json` generation, parser-state reports,
  JSON summaries, and `parser.c` emission do not require extra installed data
  files from this repository.

## Run the Bounded Release Checks

For the accepted bounded release-readiness gate:

```bash
timeout 30 zig build test-release --summary all
```

For faster local checks while editing:

```bash
timeout 30 zig build test --summary all
timeout 30 zig build test-cli-generate --summary all
timeout 30 zig build test-pipeline --summary all
```

`test-release` also includes runtime-link proofs and the bounded heavy
compatibility suite, so it takes longer than the fast local gates.

## Load and Inspect a Grammar

Validate and summarize a grammar:

```bash
zig build run -- generate path/to/grammar.json
```

Load a JavaScript grammar through Node:

```bash
zig build run -- generate --js-runtime node path/to/grammar.js
```

Print prepared grammar IR:

```bash
zig build run -- generate --debug-prepared path/to/grammar.json
```

Print parser states that reference a rule:

```bash
zig build run -- generate --report-states-for-rule expression path/to/grammar.json
```

Print parser emission and optimization statistics:

```bash
zig build run -- generate --json-summary path/to/grammar.json
zig build run -- generate --json-summary --minimize path/to/grammar.json
```

## Generate `node-types.json`

To write `node-types.json`:

```bash
mkdir -p out
zig build run -- generate --output out path/to/grammar.json
```

The output file is:

```text
out/node-types.json
```

This file is useful for editor tooling, semantic classification, documentation,
and downstream code that needs to know the named node and field surface of a
grammar.

## Generate Experimental `parser.c`

To emit parser C:

```bash
mkdir -p out
zig build run -- generate --output out --emit-parser-c path/to/grammar.json
```

The output files are:

```text
out/node-types.json
out/parser.c
```

To enable the experimental generated GLR loop and temporary result API:

```bash
zig build run -- generate --output out --emit-parser-c --glr-loop path/to/grammar.json
```

When `--glr-loop` is enabled, generated C exposes:

- `ts_generated_parse`
- `ts_generated_parse_result`
- `ts_generated_result_tree_string`
- `ts_generated_result_api_status`
- `ts_generated_error_recovery_status`

This API is temporary. It is useful for focused generated-runtime proofs and
experiments, but it is not a stable replacement for the upstream Tree-sitter C
runtime API.

## What You Can Get From This Project

You can use the project to get:

- grammar validation for `grammar.json` and supported `grammar.js`
- prepared grammar IR dumps
- generated `node-types.json`
- parse-table diagnostics
- parser-emission size and optimization summaries
- experimental generated `parser.c`
- generated GLR result/tree-string experiments
- compatibility artifacts under `compat_targets/`

You should not currently expect:

- complete upstream `tree-sitter generate` parity
- corpus-level runtime equivalence for all grammars
- first-class CLI output for compatibility reports
- stable public generated-tree ABI
- broad support for every external scanner grammar beyond the promoted proofs

## Example: Build a Web Code Highlighter

A practical highlighter needs two parts:

1. A parser or tokenizer that identifies syntax structure.
2. A browser-side renderer that maps syntax classes to HTML and CSS.

Today, `gen-z-sitter` can help with grammar metadata and experimental parser C.
For production browser highlighting, the simplest path is still to use
Tree-sitter's browser/runtime ecosystem for parsing, and use `gen-z-sitter` to
inspect or generate supporting grammar artifacts. For experiments, you can
compile generated C to WebAssembly yourself.

### Step 1: Generate Grammar Metadata

```bash
mkdir -p out
zig build run -- generate --output out path/to/grammar.json
```

Use `out/node-types.json` to understand named nodes and fields. A highlighter
can use this metadata to decide which node types should receive classes such as
`keyword`, `string`, `number`, `comment`, or `function`.

### Step 2: Generate Experimental Parser C

```bash
zig build run -- generate --output out --emit-parser-c --glr-loop path/to/grammar.json
```

This writes `out/parser.c`. For a browser experiment, compile that parser with a
small C wrapper to WebAssembly. The wrapper can call:

```c
bool ts_generated_parse_result(
  const char *input,
  uint32_t length,
  TSGeneratedParseResult *out_result
);

bool ts_generated_result_tree_string(
  const TSGeneratedParseResult *result,
  char *buffer,
  uint32_t capacity
);
```

The tree-string function gives a simple debugging representation. For a real
highlighter, expose the generated result nodes to JavaScript instead of only a
string.

### Step 3: Map Nodes to HTML

The browser side can use a simple class map:

```js
const classByNodeType = {
  string: "tok-string",
  number: "tok-number",
  comment: "tok-comment",
  identifier: "tok-ident",
};
```

For each parsed node:

- read its symbol or node type
- read its byte range
- escape the corresponding source text
- wrap the text in a `<span>` with the mapped class

Example output:

```html
<pre class="code">
  <span class="tok-keyword">const</span>
  <span class="tok-ident">answer</span>
  =
  <span class="tok-number">42</span>;
</pre>
```

Example CSS:

```css
.code {
  background: #101214;
  color: #e7e9ea;
  padding: 12px;
  overflow: auto;
}

.tok-keyword { color: #7cc7ff; }
.tok-string { color: #9ed072; }
.tok-number { color: #f0c674; }
.tok-comment { color: #8a9299; }
.tok-ident { color: #e7e9ea; }
```

### Current Highlighter Caveats

- Generated parser C is experimental.
- The generated result API is temporary.
- Error recovery is bounded and not full Tree-sitter runtime parity.
- External scanners are proven only for focused promoted targets.
- For production browser highlighting today, use this project as a generator and
  inspection tool, and keep parser/runtime integration behind your own tests.

## Useful Compatibility Artifacts

The release boundary is summarized in:

```text
compat_targets/release_boundary.json
```

Other useful compatibility artifacts:

```text
compat_targets/shortlist.json
compat_targets/shortlist_report.json
compat_targets/shortlist_inventory.json
compat_targets/external_repo_inventory.json
compat_targets/external_scanner_repo_inventory.json
```

Refresh routine artifacts with:

```bash
timeout 30 zig run update_compat_artifacts.zig
```

The heavier parser-boundary probe is separate:

```bash
timeout 30 zig run update_parser_boundary_probe.zig
```
