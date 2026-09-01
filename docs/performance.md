# Performance budgets and benchmark profiles

Pinchos's pitch is efficiency: native `NSStatusItem`s, no runtime bloat, idle physical
footprint under ~15MB for the flagship three-item workload, and effectively zero idle
CPU between ticks (see [README.md](../README.md)). This document defines the benchmark
profiles that back those claims, what's enforced automatically today, and how to run a
controlled measurement locally. It tracks [issue #55](https://github.com/douglasjarquin/pinchos/issues/55).

## Two enforcement tiers

Hosted CI runners are noisy: wall-clock timing and reported memory vary run to run and
runner to runner. Pinchos therefore splits performance evidence into two tiers:

1. **Deterministic architectural invariants, in ordinary PR CI.** These don't measure
   wall-clock time or absolute memory; they prove structural properties that can only be
   true or false, regardless of runner noise, e.g. "a manual-interval item never holds a
   timer" or "retained output never exceeds its fixed per-runner byte budget." Enforced by
   `.github/workflows/verify.yml` (`swift build`, `swift test`, `swift build -c release`).
2. **Wall-clock/RSS/wakeup budgets, run manually on a controlled machine.** These are the
   absolute product claims (the "under 15MB" line in the README). They're measured with
   the real release binary using `footprint`'s `phys_footprint` (Apple's own private-memory
   metric — see the note in [`docs/manual-qa/0.1.0-evidence.md`](manual-qa/0.1.0-evidence.md) on
   why this is preferred over `ps` RSS), run repeatedly, and compared against both an
   absolute budget and a percentage regression threshold. There is currently no scheduled
   CI workflow for this tier; it is a documented local command (below) run by a maintainer
   before/after changes that touch scheduling, command execution, output, watcher, reload,
   or AppKit diagnostics. Promoting this to a scheduled/self-hosted workflow with retained
   artifacts is tracked as follow-up work under issue #55, not claimed as done here.

Do not let a single noisy local run block a change forever: rerun a failing profile at
least once before treating it as a regression, and prefer the median of 3+ samples over
any single sample.

## Benchmark profiles

| Profile | Shape | What it measures | Primary failure mode it guards |
|---|---|---|---|
| **P0** | Missing config, app idle for a fixed window | CPU, wakeups, memory, thread count, descriptors | A permanent polling/timer loop with no config (#51) |
| **P1** | 3 items, 60s intervals (the documented "flagship" shape) | Settled `phys_footprint`, RSS, idle CPU, wakeups, threads, descriptors, timer source count | The headline product budget: idle footprint and CPU |
| **P2** | 25 items, mixed 5s/60s/manual intervals, a few actions | Startup time, first-value latency, steady memory, spawn concurrency, idle behavior | Moderate real-world configs becoming disproportionately heavy |
| **P3** | 100 items, aligned intervals, short commands | Peak active commands, queue depth, threads, descriptors, memory, post-burst recovery | Unbounded concurrency under simultaneous ticks (#49) |
| **P4** | Simultaneous bounded stdout/stderr at multiple rates | Throughput, bytes copied, peak memory, truncation correctness, event-loop responsiveness | Superlinear output-tail copying / unbounded buffers (#50, #53) |
| **P5** | Large config parse/apply, incremental edits, add/remove/reorder, many active commands during quit/signal | Main-thread stalls, reload latency, shutdown latency | Off-main-thread parse violations and lifecycle latency that scales with runner count (#52, #54) |

P0–P1 are the profiles with the most direct product commitment (the README's "under 15MB
/ effectively zero idle CPU" claim is specifically P1). P2/P3 characterize scaling
behavior rather than typical end-user UX. P4/P5 target specific known-risky subsystems
(output draining, reload, shutdown) rather than a single number.

## What ordinary CI enforces today

`.github/workflows/verify.yml` runs, in order, on every PR and every push to `main`:

1. `swift build` — debug build, for fast iteration and to catch build breaks early.
2. `swift test` — the full `PinchosCoreTests` + `pinchosTests` suite, including the
   deterministic resource-invariant tests below.
3. `swift build -c release` — proves the release configuration (the only configuration
   the performance claims are made about) actually compiles, catching e.g. optimizer-only
   failures or `#if` branches that only trigger in release builds.

Deterministic resource-invariant tests, run as part of `swift test`:

- **Timer/source bounds** — [`Tests/pinchosTests/PerformanceInvariantTests.swift`](../Tests/pinchosTests/PerformanceInvariantTests.swift)
  builds real `ManagedItem`s through `StatusItemController` with an instrumented timer
  factory and proves: a manual-interval item never allocates a `DispatchSourceTimer`; the
  live timer count always equals the current number of scheduled items, across
  reconfiguration, removal, and addition (no leak, no accumulation); and `shutdown()`
  cancels every remaining timer source. This is the architectural half of the P0/P1 "no
  runaway timer" budget — it can't measure CPU%, but it can prove the source count is
  bounded by construction.
- **Output buffer budgets** — `TailByteBuffer` (the ring buffer backing every command's
  retained stdout/stderr) and its shared, process-wide `OutputMemoryBudget` are covered at
  the unit level by [`Tests/PinchosCoreTests/TailByteBufferTests.swift`](../Tests/PinchosCoreTests/TailByteBufferTests.swift)
  (exact-capacity retention, tail-not-head eviction, wraparound, mutual exclusion across
  buffers sharing one budget) and at the multi-runner integration level by
  `CommandExecutionTests.testAggregateOutputBudgetCapsRetainedBytesAcrossManyRunners` (many
  concurrent runners, each individually configured to retain more than its fair share,
  never collectively exceed the shared budget). [`Tests/PinchosCoreTests/PerformanceInvariantTests.swift`](../Tests/PinchosCoreTests/PerformanceInvariantTests.swift)
  adds one more thing neither covers: an end-to-end, timing-independent proof (`head -c`,
  not `yes`, so there's no process-scheduling race) that a real `CommandRunner` retains
  *exactly* its explicit per-runner budget and *exactly* the tail of the
  stream through the same `CommandRunner` path `ManagedItem` uses in production. Together
  these are the architectural half of the P4 budget.
- **Menu construction cost, independent of retained output size** (issue #53) —
  [`Tests/pinchosTests/StatusItemControllerTests.swift`](../Tests/pinchosTests/StatusItemControllerTests.swift)`.testMenuConstructionCostIsBoundedIndependentOfRetainedOutput`
  builds a real lifecycle menu against the maximum allowed retained output
  (a pathological 4MiB retained value) simultaneously across the primary value,
  primary stderr, and a menu action's stdout/stderr, and proves the combined size of every
  resulting menu title stays a small, fixed budget — the deterministic, timing-free half
  of "menu construction stays under a measured main-thread latency budget in a release
  build." [`Tests/PinchosCoreTests/DiagnosticPreviewFormatterTests.swift`](../Tests/PinchosCoreTests/DiagnosticPreviewFormatterTests.swift)
  covers the underlying `DiagnosticPreviewFormatter` at the unit level (byte/line/cluster
  boundaries, control-character and bidi sanitization, grapheme-cluster-safe truncation).
  A real release-build wall-clock measurement of this same scenario is deferred to the
  manual P4 tier above, consistent with this repo's policy against wall-clock assertions
  in hosted CI.

These tests are intentionally deterministic (fixed byte counts, injected timer factories,
no wall-clock assertions) so they never flake on a noisy hosted runner, unlike the P0–P5
absolute measurements below.

Existing process-lifecycle correctness tests (`Tests/PinchosCoreTests/CommandExecutionTests.swift`,
`Tests/pinchosTests/SignalIntegrationTests.swift`, `Tests/pinchosTests/ShutdownCoordinatorTests.swift`)
already cover related invariants — bounded process-group cleanup, single-flight shutdown,
signal handling — that this document doesn't duplicate.

## Running a local P1 measurement

[`scripts/perf/measure_footprint.sh`](../scripts/perf/measure_footprint.sh) is a harness
stub for the P1 profile: it builds the release binary, runs it against a disposable
three-item/60s config in a scratch `XDG_CONFIG_HOME`, waits for it to settle, samples
`footprint --json`'s `phys_footprint` a few times, and prints one JSON object identifying
the commit SHA, working-tree dirty state, macOS version, hardware model, architecture,
memory size, and Swift toolchain version alongside the samples:

```sh
scripts/perf/measure_footprint.sh            # 15s settle, 3 samples (defaults)
scripts/perf/measure_footprint.sh 20 5       # 20s settle, 5 samples
```

This requires a real, logged-in macOS session (not a CI sandbox) and the Xcode command
line tools (`footprint`). It's network-free and touches no files outside a temporary
directory. It is a stub, not a full harness: it only covers P1, it doesn't yet retain a
baseline to diff against, and its rerun/threshold policy is the manual guidance in this
document rather than automated pass/fail. Extending it to P0–P5, a baseline/threshold
file, and a scheduled or self-hosted CI workflow that retains artifacts is tracked as
follow-up work in the 0.1 roadmap.

The retained reference sample was captured at runtime commit `44bb2b3d3fd8bc90ae52e4d2da2dd7b4b0e7aeb6` and is recorded in [`docs/manual-qa/0.1.0-p1.json`](manual-qa/0.1.0-p1.json).
The later evidence-only commit does not change executable code.
The sample records three settled `phys_footprint` values between 13.78 MB and 13.81 MB on an arm64 Mac15,11, below the 15 MB P1 budget.

For a worked example of this measurement (a prior manual pass, before this script
existed), see [`docs/manual-qa/0.1.0-evidence.md`](manual-qa/0.1.0-evidence.md), section "Idle
RSS with the example shape" — `phys_footprint: 14 MB`, under the 15MB bar.

## Absolute budgets (current)

| Profile | Metric | Budget |
|---|---|---|
| P1 | `phys_footprint`, settled, 3 items @ 60s | < 15 MB |
| P1 | Idle CPU between ticks | Effectively zero (no busy-poll; timer-driven only) |

Only P1 has a ratified absolute budget today, matching the README's product claim. P0 and
P2–P5 are defined as profiles with metrics to collect, but don't yet have ratified
absolute thresholds — establishing those (and the regression-percentage policy alongside
them) requires the repeated-sample reference-hardware runs described above, and is
follow-up work rather than something this change fabricates numbers for.

Intentional budget changes require an explicit issue/PR with before/after evidence — see
the verification plan in issue #55.
