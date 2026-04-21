# Zig 0.16 Notes

This file records the Zig 0.16 changes that showed up while fixing `zig build` in this repository.

## Main / Process Startup

- `std.heap.GeneralPurposeAllocator` is gone from the old call sites we had. For this codebase, the simpler migration was to use `pub fn main(init: std.process.Init) !void` and take the allocator from `init.gpa`.
- `std.process.argsAlloc` / `std.process.argsFree` are no longer the right entrypoint helpers here. Zig 0.16 exposes process args through `init.minimal.args`, and the portable way we used was `try init.minimal.args.toSlice(arena)`.
- Child process termination tags are now lowercase. Example: `.Exited` became `.exited`.

## I/O and Filesystem

- `std.fs.File` call sites used by this repo had to move to `std.Io.File`.
- Direct writes like `std.fs.File.stdout().writeAll(...)` were replaced with Zig 0.16 patterns such as:
  - `std.Io.File.stdout().writeStreamingAll(io, bytes)`
  - `file.writer(io, &buffer)` for buffered writer-based output
- Filesystem helpers that previously lived under `std.fs.cwd()` now come from `std.Io.Dir.cwd()` in the code we touched.
- Absolute/open dir helpers moved to `std.Io.Dir.openDirAbsolute(...)` and `std.Io.Dir.cwd().openDir(...)`.
- Directory creation and file read/write helpers in this repo now use:
  - `std.Io.Dir.cwd().createDirPath(io, path)`
  - `std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_bytes))`
  - `std.Io.Dir.cwd().writeFile(io, .{ ... })`

## Diagnostics and Writers

- Error unions that previously referenced `std.fs.File.WriteError` had to be updated. In the writer-based code paths we fixed, `std.Io.Writer.Error` was the relevant replacement.
- `std.array_list.Managed(...).writer()` is not the pattern to rely on anymore in Zig 0.16 for this repo. The compatible replacement we used was `std.Io.Writer.Allocating`.
- Typical migration:
  - before: build bytes into `std.array_list.Managed(u8)` and call `.writer()`
  - after: use `var out: std.Io.Writer.Allocating = .init(allocator)` and pass `&out.writer`

## Maps and String-Keyed Collections

- `std.StringArrayHashMap(...)` is no longer available as it used to be referenced here.
- For the code we updated, `std.StringHashMap(...)` was the direct replacement that compiled cleanly.

## Environment Variables

- `std.process.getEnvVarOwned(...)` is not available in the old form we used.
- The replacement we adopted was `std.process.Environ.getAlloc(runtime_environ, allocator, key)`.
- Because several deep helpers in this repo needed environment access, we added a tiny runtime holder so `main` can provide the current `std.process.Environ`.

## Process Execution

- `std.process.Child.run(...)` was replaced in the touched code with `std.process.run(allocator, io, .{ ... })`.
- This means helper code that runs subprocesses now also needs access to a `std.Io` value.

## Formatting Helpers

- `std.io.fixedBufferStream(...)` is not available under that old path.
- For small formatting helpers, replacing it with `std.fmt.bufPrint(...)` was the simplest fix.

## Timers / Timing

- `std.time.Timer` is not available under the old API this repo used.
- For the build fix, I removed the elapsed-time measurement from the affected parse-table logging helpers and kept the progress logs themselves.
- If timing is needed again, it should be reintroduced against the current Zig 0.16 timing API rather than restoring the old calls.

## Practical Advice For This Repo

- Prefer `std.process.Init` in `main` instead of manually reconstructing allocators and argv.
- Prefer `std.Io.*` APIs over older `std.fs.*` / direct file-handle assumptions.
- Prefer `std.Io.Writer.Allocating` when generating strings or file contents in memory.
- Expect older helper names in `std.process`, `std.time`, and `std.fs` to have moved or been removed.

