# HOWTO: Write Zig Code In This Repository

This HOWTO expands the general Zig coding skill into concrete practices for
`gen-z-sitter`. It is organized around the skill checklist and points to local
examples where the repository already shows the intended pattern.

## Guiding Rule: Trust Local Code First

Zig changes quickly, and this repository tracks Zig 0.16.x-era APIs. Treat the
installed compiler, local standard library, and nearby project code as the source
of truth.

In practice, start by checking existing code before writing new code. For
example, environment access is not done through older process APIs here. The
local pattern is in `src/lexer/serialize.zig`:

```zig
const value = std.process.Environ.getAlloc(
    runtime_io.environ(),
    std.heap.page_allocator,
    "GEN_Z_SITTER_PARSE_TABLE_PROFILE",
) catch "";
defer if (value.len != 0) std.heap.page_allocator.free(value);
```

That example also shows another repo-specific pattern: runtime IO and
environment state flow through `src/support/runtime_io.zig`, so code works in
normal execution and in tests.

## First Checks

### Check The Zig Version When Compatibility Matters

Run:

```bash
zig version
```

Use this before changing standard library calls, build system code, IO code, or
allocator/container usage. The README currently documents Zig 0.16.x as a
requirement, and `docs/zig-0.16-notes.md` records migration notes that have
already mattered in this repo.

### Inspect Nearby Code Before Editing

Do not start from generic Zig examples when a nearby module already has a local
pattern. For example, test filters are wired through `build.zig`, not through
ad-hoc test runners:

```zig
const test_filter = b.option([]const u8, "test-filter", "Filter tests by name substring");

const unit_tests = b.addTest(.{
    .root_module = createTestModule(b, "src/fast_test_entry.zig", target, optimize),
    .filters = if (test_filter) |f| &.{f} else &.{},
});
```

That pattern is repeated for parse-table, pipeline, CLI, behavioral,
compatibility, and runtime-link test steps.

### Search The Installed Stdlib When An API Is Uncertain

If you are not sure whether a standard library API exists in the installed Zig,
search it directly:

```bash
std_dir=$(zig env | awk -F'"' '/\.std_dir/ {print $2}')
rg -n "pub fn .*Environ|getAlloc|MultiReader" "$std_dir"
```

For normal work, a simpler targeted search against the known Zig installation
path is enough. The important part is the habit: verify the installed stdlib
instead of guessing from another Zig version.

### Use `zig env` For Paths And Cache Questions

Run:

```bash
zig env
```

Use it when build behavior depends on cache directories, global cache state, or
the compiler's stdlib location. This is more reliable than assuming where Zig is
installed on a given machine.

## Editing Workflow

### Read The Smallest Useful Context

Prefer `rg`, then read only the relevant file ranges. Examples:

```bash
rg -n "run-compare-upstream|test-filter|test-release" build.zig
rg -n "deinit\\(|toOwnedSlice\\(|errdefer" src/lexer src/parse_table src/support
```

The goal is to learn the local shape of a change before editing. For parser
parity work, `docs/plans/tree-sitter-parity-2026-04-29.md` is also part of the
context because it defines the current batch rule and evidence expectations.

### Make Focused Changes

Keep changes inside the module that owns the behavior. If a change touches lexer
serialization, prefer updating `src/lexer/serialize.zig` and its local tests
before reaching into parser emission. If a change touches runtime process
capture, `src/support/process.zig` owns the result type and cleanup contract:

```zig
pub const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,
    max_rss_bytes: ?usize = null,

    pub fn deinit(self: RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};
```

That contract makes callers responsible for `result.deinit(allocator)`.

### Run `zig fmt` On Touched Zig Files

After editing Zig files, format only the files you touched:

```bash
zig fmt src/support/process.zig
```

For documentation-only changes like this HOWTO, `zig fmt` is not needed.

### Run Focused Tests First

Use the repo's build filters instead of jumping straight to broad gates:

```bash
zig build test -Dtest-filter=stringifyAlloc
zig build test-pt -Dtest-filter=expected
zig build test-link-runtime -Dtest-filter=JavascriptTernary
```

The filter plumbing is in `build.zig`, where each test step passes
`.filters = if (test_filter) |f| &.{f} else ...`.

### Escalate To Broader Gates When The Surface Is Shared

Use broader gates when touching shared behavior, generated parser output,
runtime-link behavior, or build configuration. The README lists common bounded
commands:

```bash
zig build test
zig build test-build-config
zig build test-cli-generate
zig build test-pipeline
zig build test-link-runtime
zig build test-compat-heavy
zig build test-release
```

`build.zig` defines `test-release` as the accepted bounded release gate by
depending on unit tests, build config tests, CLI generation tests, pipeline
tests, runtime-link tests, compatibility-heavy tests, and the generate smoke
step.

## Code Style

### Prefer Clear Ownership Over Cleverness

Make ownership explicit in type contracts. `src/support/process.zig` returns a
`RunResult` with owned `stdout` and `stderr`, then provides `deinit` to free
them. Callers such as `src/grammar/js_loader.zig` follow that contract:

```zig
var result = process_support.runCapture(gpa, &.{ runtime, "-e", "...", path }) catch {
    return error.IoFailure;
};
defer result.deinit(gpa);

return gpa.dupe(u8, result.stdout);
```

The `dupe` is important: the returned slice must outlive `result.deinit`.

### Use `const` By Default

Use `const` unless the binding itself changes. `build.zig` is a good example:
targets, options, build steps, and command objects are mostly `const` bindings.
Use `var` for mutable state such as counters, builders, and temporary buffers:

```zig
var initialized: usize = 0;
errdefer {
    deinitSerializedLexTables(allocator, tables[0..initialized]);
    allocator.free(tables);
}
```

If the compiler reports "local variable is never mutated", make the binding
`const` instead of silencing the diagnostic.

### Keep Error Sets And Error Unions Explicit

Expose meaningful failure surfaces. `src/grammar/js_loader.zig` defines a loader
error that combines JSON loader errors with the process-specific failure:

```zig
pub const LoadError = json_loader.LoadError || error{
    ProcessFailure,
};
```

The public functions then return `LoadError![]u8` or
`LoadError!json_loader.LoadedJsonGrammar`, so callers can distinguish parse
failures, IO failures, invalid paths, and process failures through the existing
loader contract.

### Use `defer` And `errdefer` For Local Cleanup

Use `defer` for normal cleanup and `errdefer` for ownership that should be
released only if the function exits with an error. `src/support/json.zig` is the
smallest pattern:

```zig
var out: std.Io.Writer.Allocating = .init(allocator);
errdefer out.deinit();

try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &out.writer);
return out.toOwnedSlice();
```

After `toOwnedSlice`, the caller owns the returned memory, so the writer must
not be deinitialized on success.

### Track Partially Initialized Arrays

When allocating an array of owned structs, track how many elements have been
initialized. `src/lexer/serialize.zig` does this for serialized lexer tables:

```zig
const tables = try allocator.alloc(SerializedLexTable, terminal_sets.len);
var initialized: usize = 0;
errdefer {
    deinitSerializedLexTables(allocator, tables[0..initialized]);
    allocator.free(tables);
}

for (terminal_sets, 0..) |terminal_set, index| {
    tables[index] = try serializeLexTableAlloc(allocator, table);
    initialized += 1;
}
```

The same pattern appears for serialized states and transitions. This avoids
freeing uninitialized memory if one element fails partway through construction.

### Avoid Hidden Lifetime Bugs

Do not store slices into maps, returned structs, or long-lived arrays unless the
backing memory outlives the owner. `src/lexer/model.zig` uses a hash map with a
compact integer key for token conflict states:

```zig
var visited = std.AutoHashMap(u64, void).init(allocator);
defer visited.deinit();

try visited.put(pairStateHash(left_start, right_start), {});
```

That design avoids using temporary closure slices as hash-map keys.

### Prefer Typed Literals When Inference Gets Ambiguous

Tagged unions and optionals are clearer with explicit types at comparison or
fallback boundaries. `src/lexer/serialize.zig` uses an explicit
`syntax_ir.SymbolRef` literal in a test:

```zig
try std.testing.expectEqual(
    syntax_ir.SymbolRef{ .end = {} },
    serialized.states[start.eof_target.?].accept_symbol.?,
);
```

The production code nearby also returns explicit union alternatives:

```zig
.accept_symbol = if (state.completion) |completion|
    .{ .terminal = @intCast(completion.variable_index) }
else if (state.nfa_states.len == 0)
    .{ .end = {} }
else
    null,
```

Use the explicit type when the compiler cannot infer the intended union from
context.

### Keep Comptime Code Readable

Use comptime parameters when they remove real duplication, but keep the call
shape obvious. `src/parser_emit/parser_c.zig` shares row-owner logic over
different serialized entry types:

```zig
fn collectStateArrayOwners(
    allocator: std.mem.Allocator,
    comptime T: type,
    states: []const serialize.SerializedState,
    comptime getEntries: fn (serialize.SerializedState) []const T,
) std.mem.Allocator.Error![]usize {
    ...
}
```

The helper remains readable because the generic parameters are few and the
specialized callbacks are plain functions such as `stateActions`, `stateGotos`,
and `stateUnresolved`.

## Common Pitfalls

### Do Not Assume Stdlib APIs From Another Zig Version

This repo already uses newer IO and process APIs such as `std.Io`,
`std.Io.Writer.Allocating`, `std.process.spawn(io, ...)`, and
`std.process.Environ`. If you see older examples online using `std.io` or older
environment helpers, verify against the installed stdlib before importing them.

Local examples:

- `src/support/runtime_io.zig` centralizes `std.Io` and `std.process.Environ`.
- `src/support/process.zig` uses `std.Io.File.MultiReader`.
- `src/support/json.zig` writes JSON through `std.Io.Writer.Allocating`.

### Fix "Variable Is Never Mutated" Directly

Zig treats many warnings as compile errors. If a binding is never mutated, make
it `const`. This is why local code usually looks like this:

```zig
const stdout = try multi_reader.toOwnedSlice(0);
errdefer allocator.free(stdout);
const stderr = try multi_reader.toOwnedSlice(1);
errdefer allocator.free(stderr);
```

Use `var` only when the binding changes or when an API requires a mutable
pointer to the object.

### Be Careful With `orelse` And Anonymous Union Literals

Anonymous literals can become ambiguous when used through `orelse` or other
optional fallback paths. Prefer an explicit union type in those cases:

```zig
const fallback = syntax_ir.SymbolRef{ .end = {} };
```

The `syntax_ir.SymbolRef{ .end = {} }` test in `src/lexer/serialize.zig` is the
same principle: make the union target explicit when inference is not the main
point of the code.

### Do Not Return Slices Of Temporary Memory

Returned slices must own or borrow stable memory. `src/grammar/js_loader.zig`
does not return `result.stdout` directly because `result.deinit(gpa)` will free
it. It returns a duplicate:

```zig
defer result.deinit(gpa);
return gpa.dupe(u8, result.stdout);
```

This is the right pattern when the source buffer belongs to a temporary result.

### Do Not Double-Free After Ownership Transfer

After `toOwnedSlice`, the caller owns the returned slice and the builder should
not also free the same memory on success. `src/support/json.zig` uses
`errdefer`, not `defer`, for the allocating writer:

```zig
var out: std.Io.Writer.Allocating = .init(allocator);
errdefer out.deinit();
return out.toOwnedSlice();
```

The same rule applies to array lists. After returning `entries.toOwnedSlice()`,
do not deinitialize the transferred backing storage on the success path.

### Arena Allocation Is Convenient But Does Not Remove Ownership Concerns

Tests often use arenas to group cleanup:

```zig
var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
defer arena.deinit();
```

That is appropriate for parse trees and temporary JSON values. But when a test
allocates with `std.testing.allocator` directly, it should free directly, as in
`src/grammar/js_loader.zig`:

```zig
const emitted = try emitGrammarJsonFromJsAlloc(std.testing.allocator, path);
defer std.testing.allocator.free(emitted);
```

### Hash Maps With Slice Keys Need Stable Storage

When a key is a slice, both hashing and equality depend on the pointed-to bytes.
Only use slice keys when the backing storage is stable for the map's lifetime.
This repo often avoids that risk by using IDs or hashes as keys. The token
conflict traversal in `src/lexer/model.zig` stores a `u64` hash in an
`AutoHashMap`, not the temporary state slices themselves.

## Build And Tests

### Prefer Project Build Steps

Use the steps defined in `build.zig`. The main development entry points are:

```bash
zig build
zig build run -- help
zig build test
zig build test-pipeline
zig build test-link-runtime
```

`build.zig` also defines specialized steps such as `run-compare-upstream`,
`run-compat-target`, `refresh-node-type-goldens`, and `run-minimize-report`.

### Use Focused Filters For Fast Iteration

The build script exposes `-Dtest-filter`, so prefer:

```bash
zig build test -Dtest-filter=serializeLexTableAlloc
zig build test-pipeline -Dtest-filter=SerializedLexicalDump
zig build test-link-runtime -Dtest-filter=ExternalScanner
```

This keeps iteration fast and makes failures easier to classify.

### For `build.zig` Changes, Test The Build Configuration

When editing `build.zig`, run the build-config test step:

```bash
zig build test-build-config
```

The file includes tests for documented custom steps:

```zig
test "custom build steps stay documented" {
    try std.testing.expect(std.mem.eql(u8, custom_step_names[0], "refresh-node-type-goldens"));
    ...
}
```

Also run the specific affected step if you changed its arguments or dependency
graph.

### For Generated Parser Work, Compare Evidence

Parser, lexer, minimizer, scanner, and C-emission changes need evidence. A
typical upstream comparison command is:

```bash
zig build run-compare-upstream \
  -Dupstream-compare-grammar=compat_targets/tree_sitter_javascript/grammar.json \
  -Dupstream-compare-output=.zig-cache/upstream-compare-javascript \
  -Dtree-sitter-dir=../tree-sitter
```

The parity plan requires focused filters first, then the accepted bounded gate
when promoted behavior changes. It also requires repo-relative paths in batch
notes and commit messages.

## Review Bias

### Lead With Correctness And Memory Safety

In review, first check ownership, lifetime, allocator pairing, error behavior,
comptime branches, and Zig-version compatibility. For example, a suspicious
change in `src/support/process.zig` should be reviewed around whether
`stdout`/`stderr` are still owned by `RunResult` and freed by `RunResult.deinit`.

### Tie Findings To Exact Files And Lines

Use precise references such as:

- `src/lexer/serialize.zig:145` for partial table initialization.
- `src/support/json.zig:4` for allocating writer ownership.
- `build.zig:16` for `-Dtest-filter` plumbing.

This keeps review comments actionable and avoids vague style arguments.

### Explain Compiler Errors In Local Terms

When debugging a compile error, identify the Zig rule and the local pattern that
fixes it. Examples:

- If a tagged union literal is ambiguous, use an explicit type like
  `syntax_ir.SymbolRef{ .end = {} }`.
- If a returned slice points into a temporary `RunResult`, duplicate it before
  `result.deinit`.
- If a builder transfers memory through `toOwnedSlice`, use `errdefer` for the
  builder cleanup instead of `defer`.

### Create Focused Tests Or Inspect Stdlib When Unsure

Do not guess on subtle standard library or parser behavior. Add a narrow test
near the affected module, or inspect the installed stdlib with `rg`. This repo
already has focused tests near the implementation: lexer serialization tests
live in `src/lexer/serialize.zig`, grammar JS loader tests live in
`src/grammar/js_loader.zig`, and build configuration tests live in `build.zig`.

For parity-sensitive work, prefer a focused fixture or comparison artifact
before changing a broad algorithm. State counts are diagnostics; the action
surface, token/symbol extraction, lex modes, external scanner rows, and emitted
runtime behavior are the correctness surfaces.
