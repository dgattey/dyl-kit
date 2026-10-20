---
name: swift-concurrency-io
description: Keep blocking work off the main actor and structure async code the DylKit way. Use when adding I/O, parsing, image decoding, persistence, networking or long-running tasks, or when dyl-lint flags a concurrency rule.
---

# Swift concurrency and I/O

`dyl-lint` and SwiftLint enforce the mechanical rules (`main_actor_blocking_io`, `blocking_semaphore`, `gcd_main_hop`, `task_in_defer`, `polling_timer`, `lock_or_unchecked_sendable`, `urlsession_shared` and the rest). When one fires, fix the shape of the code; don't reach for `lint:allow` unless the hit is verifiably benign, and then write the reason.

## Shape

- The main actor renders. Parsing, file and Keychain I/O, image decoding and layout math run in an `actor` or a `nonisolated` async function, and the result hops back once.
- Mark functions that block with a `- Blocking:` doc line so callers know to move them.
- Load heavy state after the first frame: show the window, then `await` the store.
- Use structured concurrency: `async let`, task groups, and `Task` handles you cancel. Long waits check `Task.isCancelled` or use cancellable sleeps.
- Coalesce duplicate work with `SingleFlight`; persist with `CodableFileStore`; keep secrets in `SecureFileVault`.
- One ordered consumer per stream (an `AsyncStream` drained by one task), never a `Task` per event.
- Typed `Codable` models only. No `JSONSerialization`, `[String: Any]`, or swallowed decode errors.
- `Duration` and `Clock`, not `Timer` polling or `DispatchQueue.asyncAfter`.
