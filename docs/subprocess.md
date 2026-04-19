# Subprocess transport

Why we don't use [swift-subprocess](https://github.com/swiftlang/swift-subprocess), and what we use instead.

## What we use

`Sources/Service/` — three layers:

- `SpawnedProcess` — `posix_spawn` + `DispatchSource.makeProcessSource(.exit)`. Hands back a `pid` and an async `waitForExit()`.
- `AnonymousPipe` — `pipe(2)` wrapper with `readEnd` / `writeEnd` and targeted close methods.
- `PipeTransport` / `DispatchIOPipeTransport` — protocol + default impl that runs one `DispatchIO` stream read per pipe and line-frames the output.

`BridgeProcess<Transport: PipeTransport>` orchestrates: three pipes, one `SpawnedProcess`, two `readLines` + one `pumpMessages` through the transport.

## Why not swift-subprocess

Latest release is 0.4 (2025-03-24), unchanged at time of writing. `main` sees CI/infra commits but no fixes or new releases. Three concrete failures on our workload, all still present on tip:

### 1. Single global worker thread serializes every spawn

`Sources/Subprocess/Thread.swift:173` — one `pthread` processes a shared work queue, and the Darwin spawn path (`Subprocess+Darwin.swift:425`) goes through it. Six `MCPConnection`s booting concurrently queue six `posix_spawn` calls on that one thread. Each takes 20–50 ms, so cold start is serialized at ~6×30 ms instead of the ~20 ms max of real parallel spawns.

### 2. DispatchIO wrapper only resumes on `done = true`

`Sources/Subprocess/IO/AsyncIO+Dispatch.swift:48` accumulates partial reads and resumes its continuation only when DispatchIO fires `done = true`. For a stream pipe, that's `length` bytes or EOF — whichever comes first.

For interactive traffic (JSON-RPC lines of a few hundred bytes, no EOF between messages), this means:

- `preferredBufferSize: 4096` with a 500-byte message → hangs forever waiting for 3596 more bytes or EOF.
- `preferredBufferSize: 1` works, but every byte costs a fresh `DispatchQueue(label: "SubprocessReadQueue")`, a DispatchIO callback, and a continuation resume. A 500-byte message pays 500 GCD round-trips.

There's no middle ground in the library's API.

### 3. Spurious `DispatchQueue` allocation per read call

Line 53 of the same file: every `AsyncIO.shared.read` call allocates a new `DispatchQueue`. With `preferredBufferSize: 1`, that's one `DispatchQueue` per byte. Under parallel test load (many subprocesses, many bytes each), GCD thread management is the bottleneck.

## What our stack does differently

### Parallel spawns

`SpawnedProcess.spawn` calls `posix_spawn` directly on whatever thread asks. No shared worker, no queue.

### One read for the subprocess lifetime

`DispatchIOPipeTransport.readLines` issues a single `channel.read(offset: 0, length: .max, queue: q)` with `setLimit(lowWater: 1)`. The handler fires every time bytes land, with whatever arrived. Partial data is line-split inline; unterminated tail buffers in a local `var` captured by the handler. Zero per-byte overhead.

### Handler before resume on DispatchSource

`ExitWatcher` (inside `SpawnedProcess`) calls `setEventHandler` and *then* `resume()`. Events in the gap would otherwise be lost — `waitForExit` arriving late would never fire.

### `F_SETNOSIGPIPE` on the stdin write end

Without it, `write(2)` to a pipe whose reader exited raises `SIGPIPE`, and the default disposition terminates the whole host process. `fcntl(fd, F_SETNOSIGPIPE, 1)` turns that into `EPIPE`.

### `withTaskCancellationHandler` on `waitForExit`

Cancelling the owning task sends `SIGTERM` to the subprocess; the exit event then resumes the waiter normally.

## When you'd still reach for swift-subprocess

- Cross-platform code. We're macOS-only.
- Bulk-output subprocesses (compile tools, archive tools) where `preferredBufferSize: 4096` and accumulating into a buffer until EOF is exactly what you want. swift-subprocess's design matches that workload.

For interactive long-lived JSON-RPC over pipes — what mcpbridge is — the library fights you. The direct stack is ~200 lines and faster by two orders of magnitude under test load.

## Pitfalls the compiler won't catch

- `DispatchSourceProcess` isn't `Sendable`-annotated. Wrap it in a class whose `Sendable` conformance is backed by `Mutex<State>` if you need to store it in a `Sendable` type (see `ExitWatcher`).
- `posix_spawn_file_actions_adddup2` / `posix_spawnattr_*` return errno on failure. Check every return code.
- The child ends of pipes must be closed in the parent *after* spawn — but we pass them to `posix_spawn_file_actions_adddup2` which dup2s them in the child. After spawn, the parent's originals are still open; close them explicitly. `BridgeProcess.run` does this via `closeReadEnd()` / `closeWriteEnd()` on the child-facing ends.
- Swift 6 strict concurrency tolerates capturing a `var` in an `@escaping` non-`Sendable` DispatchIO handler, because the handler type isn't `@Sendable`. The captured var lives in a compiler-generated box — same cost as a class field, no Mutex needed because DispatchIO serializes the handler on its queue.
