# Zig 0.16 Notes

This file records the Zig 0.16 changes that showed up while fixing `zig build` in this repository.

It is split into:

- official migration themes from Zig 0.16 release notes
- local repository choices made to get this codebase building

## Official 0.16 Themes

### I/O as an Interface

Zig 0.16 moves a large part of filesystem and process work behind `std.Io`.

In practice, this means code that used to call old `std.fs.*` and process helpers directly often now needs an explicit `std.Io` value.

Examples relevant to this repo:

- `std.fs.File`-style usage becomes `std.Io.File`
- `std.fs.cwd()`-style usage becomes `std.Io.Dir.cwd()`
- file reading/writing helpers now take `io`
- process helpers now take `io`

### "Juicy Main"

Zig 0.16 supports `pub fn main(init: std.process.Init) !void`.

This is the preferred migration path when a program needs:

- allocator access via `init.gpa`
- an arena via `init.arena`
- process args via `init.minimal.args`
- environment access via `init.minimal.environ`
- an I/O implementation via `init.io`

For this repo, switching `main` to `std.process.Init` was the cleanest way to adapt several removed helpers at once.

### Environment Variables and Process Arguments Are Non-Global

One of the important Zig 0.16 changes is that process args and environment variables are no longer treated as globally available in the old style.

The release-note direction is to pass what you need down from `main`, or to use the process environment objects made available there.

This matters because old patterns such as ad hoc global env access and convenience argument helpers do not map cleanly to 0.16.

## Concrete API Changes Hit In This Repo

### Main / Startup

- old manual allocator startup was replaced with `pub fn main(init: std.process.Init) !void`
- `std.process.argsAlloc` / `std.process.argsFree` were replaced with `init.minimal.args.toSlice(...)`
- child process termination tags are lowercase now, for example `.Exited` became `.exited`

### Filesystem / Process

- `std.fs.File.stdout().writeAll(...)` was replaced with `std.Io.File.stdout().writeStreamingAll(io, ...)`
- buffered file output now uses `file.writer(io, &buffer)`
- `std.fs.cwd().readFileAlloc(...)`-style code became `std.Io.Dir.cwd().readFileAlloc(io, ..., .limited(...))`
- directory creation moved to `std.Io.Dir.cwd().createDirPath(io, path)`
- subprocess execution moved from `std.process.Child.run(...)` to `std.process.run(allocator, io, .{ ... })`

### In-Memory Writers

- older `ArrayList` writer usage was not a good fit anymore in the touched code
- `std.Io.Writer.Allocating` worked well as the replacement when building strings or generated files in memory

Typical migration in this repo:

- before: `std.array_list.Managed(u8)` plus `.writer()`
- after: `var out: std.Io.Writer.Allocating = .init(allocator)` plus `&out.writer`

### Other Renames / Removals

- `std.fs.File.WriteError` references were updated to `std.Io.Writer.Error` in writer-oriented code paths
- `std.StringArrayHashMap(...)` references were replaced with `std.StringHashMap(...)` where that was sufficient
- `std.io.fixedBufferStream(...)` was replaced with `std.fmt.bufPrint(...)` in the small formatting helpers we touched

### Timing

Zig 0.16 timing is part of the newer `std.Io` model rather than the older runtime-style `std.time` helpers.

The important types called out by the release notes are:

- `std.Io.Clock`
- `std.Io.Duration`
- `std.Io.Timestamp`
- `std.Io.Timeout`

Useful migration intuition:

- old `std.time.Instant`-style ideas map to `std.Io.Timestamp`
- old timer-style elapsed-time measurement also maps toward `std.Io.Timestamp`
- sleeping and timeout work is now expressed through `io` plus typed durations/timeouts

The release notes also mention improved clock-resolution handling, so timing code should be written against the new `Clock` / `Timestamp` / `Timeout` APIs instead of restoring old `std.time.Timer` assumptions.

## Local Repo Choices

### Runtime I/O Holder

The Zig 0.16 release-note direction is to pass `io`, args, and environment data down from `main`.

This repo mostly follows that at the top level:

- `main` now takes `std.process.Init`
- `runGenerate` now takes `io`

However, to keep the patch smaller while fixing the build, I also added a tiny runtime holder in `src/support/runtime_io.zig` for:

- `std.Io`
- `std.process.Environ`

This was a pragmatic compatibility shortcut for deep helper layers such as:

- filesystem wrappers
- process wrappers
- parse-table progress/env checks

It is acceptable as a local transition aid, but it is not the ideal long-term 0.16 style.

### Timers

The old `std.time.Timer` usage in parse-table logging no longer compiled as written.

For the build fix, I removed elapsed-time measurement from those progress logs and kept the progress messages themselves.

If detailed timing is needed again, it should be reintroduced against the current Zig 0.16 timing API rather than by restoring the old calls.

## Recommended Follow-Up For This Repo

- Prefer threading `io` and environment data explicitly from `main` rather than relying on the runtime holder in deeper modules.
- Prefer `std.Io.*` APIs when touching filesystem or process code.
- Prefer `std.process.Init`-based startup for new command entrypoints.
- Treat old `std.fs`, `std.process`, and `std.time` helper names with suspicion when upgrading code to Zig 0.16.
