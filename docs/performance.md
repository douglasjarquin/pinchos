# Performance budgets and benchmark profiles

Pinchos's pitch is efficiency: native `NSStatusItem`s, no runtime bloat, idle physical
footprint under ~15MB for the flagship three-item workload, and effectively zero idle
CPU between ticks. Those absolute numbers are the P1 budget in this document, with
evidence in [`docs/manual-qa/0.1.0-evidence.md`](manual-qa/0.1.0-evidence.md).
This document defines the benchmark profiles that back those claims, what's enforced
automatically today, and how to run a controlled measurement locally. It tracks
[issue #55](https://github.com/douglasjarquin/pinchos/issues/55).

## Two enforcement tiers

Hosted CI runners are noisy: wall-clock timing and reported memory vary run to run and
runner to runner. Pinchos therefore splits performance evidence into two tiers:

1. **Deterministic architectural invariants, in ordinary PR CI.** These don't measure
   wall-clock time or absolute memory; they prove structural properties that can only be
   true or false, regardless of runner noise, e.g. "a manual-interval item never holds a
   timer" or "retained output never exceeds its fixed per-runner byte budget." Enforced by
   `.github/workflows/verify.yml` (`swift build`, `swift test`, `swift build -c release`).
2. **Wall-clock/RSS/wakeup budgets, run manually on a controlled machine.** These are the
   absolute product claims (the P1 "under 15MB" line below). They're measured with
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

P0–P1 are the profiles with the most direct product commitment (the P1 "under 15MB /
effectively zero idle CPU" budget below). P2/P3 characterize scaling
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
- **Request counts, non-blocking menus, and lifecycle bounds** (issue #129) - the same
  `PerformanceInvariantTests` files prove exact invocation counts for source reuse,
  the #124 30s retry gate, and that a successful manual row is not refreshed by opening
  the menu; that a cap of 2 is visible in-process (some overlapping slot count equals 2,
  none exceed 2) and queued waiters start in FIFO enqueue order; that a fresh menu open
  starts no refresh and that menu construction returns while a command is blocked on a
  fifo (row value still nil, one refresh task); that three apply/reorder/remove/shutdown
  iterations while grandchild `sleep` processes are running do not grow timer, source,
  or post-shutdown descriptor counts, that removed `ManagedItem`s and menu
  `representedObject` targets become nil, that every appended grandchild pid is dead
  after removal and after shutdown, and that an in-flight menu-row refresh task goes
  from 1 to 0 on removal; and that producing 96 KiB per item retains each string at
  most the 64 KiB per-runner cap (a source may hold two copies: `value` plus
  `lastExecution.stdout`, about 2x cap) with truncation reported, independently of
  the 8 MiB active `OutputMemoryBudget` and of the diagnostic/menu title snapshot.
  A later refresh of the same source replaces those strings with the new result.
  Those tests do not assert wall-clock durations or RSS.
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

## Running the selected local profiles

The documented maintainer command is:

```sh
mise run perf
```

That is `scripts/perf/measure_footprint.sh --profile all`.
Runtime is about 1.5 minutes per profile (15s settle + samples + 60s IDLEW window) and about 3 minutes for `mise run perf` plus the release build.
It builds the release binary once and runs the two selected profiles against disposable configs in a scratch `XDG_CONFIG_HOME`:

| Profile | Shape | Local fixtures |
|---|---|---|
| **P1** (`p1`) | 3 items, 60s intervals | `echo` / `date` only |
| **five** (`five`) | 5 items, 60s intervals, cached and manual menu values, duplicate `echo 42` sources, in-flight `sleep 120`, `exit 1` | no network, no provider credentials |

Both profiles print commit SHA, dirty state, macOS version, hardware model, architecture, memory size, Swift toolchain, `phys_footprint` samples, RSS, idle CPU, numeric FD counts (`lsof -a -d 0-65535`), thread/child counts, `top` IDLEW over a 60s interval (the timer cadence), SIGTERM cleanup of recorded descendants, an Accessibility probe, and live compact-menu open latency when `AXIsProcessTrusted()` is true.
When Accessibility is trusted but the extras item cannot be reached (menu-bar overflow or notch), `mise run perf` exits 1.
Numeric first arguments still mean settle seconds and sample count for compatibility:

```sh
mise run perf                                   # both profiles, 15s settle, 3 samples
scripts/perf/measure_footprint.sh               # P1 only (defaults)
scripts/perf/measure_footprint.sh --profile p1 20 5
scripts/perf/measure_footprint.sh --profile five
```

This requires a real macOS session and the Xcode command line tools (`footprint`).
It is network-free.
It writes scratch configs under a temporary `XDG_CONFIG_HOME` and builds the release binary into `.build/release`.
It does not retain a baseline file to diff against, and it is not a PR gate.
Extending it to P0/P2–P5, a baseline/threshold file, and a scheduled workflow remains follow-up rather than something this change fabricates thresholds for.

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

Only P1 has a ratified absolute budget today. P0 and
P2–P5 are defined as profiles with metrics to collect, but don't yet have ratified
absolute thresholds — establishing those (and the regression-percentage policy alongside
them) requires the repeated-sample reference-hardware runs described above, and is
follow-up work rather than something this change fabricates numbers for.

The five-item mixed profile is a characterization workload for issue #129, not a second absolute budget.
Its `sleep 120` item uses `timeout = "180s"` so it is still running at SIGTERM and descendant cleanup is checked with a command in flight.
Completed-cache `String` size is measured in ordinary tests: each retained string is capped at 64 KiB per stream, and one source can hold two such strings (`value` and `lastExecution.stdout`, about 2x cap).
That is a separate bound from the 8 MiB active-output budget.
A refresh of the same source replaces those strings with the new result (`testCompletedCacheReplacesOnRefreshAndDropsWhenTheLastConsumerReleases` and the blob-0 step in the UI-size test), so this tree does not add an eviction framework.

Appending an item (a non-left-edge config change) does a full native rebuild that cancels in-flight commands.
That is known `ConfigDiff` / `StatusItemController` behavior and matters for reload-while-running; it is not changed here.

Intentional budget changes require an explicit issue/PR with before/after evidence — see
the verification plan in issue #55.

## Issue #129 Mac measurements

Historical P1 samples stay historical: commit `44bb2b3d` recorded 13.78–13.81 MB on Mac15,11, and the earlier manual pass recorded 14 MB.
This section records a new controlled-Mac run of the selected profiles after #123, #124, #125, and #126 landed on `main` (`51462ca`).
#168 accessibility work is parked on a separate branch and is not in these binaries.

`mise run verify` on this machine exited 0 in 122.46s: 208 `pinchosTests` and 215 `PinchosCoreTests`, then a release build.

`mise run perf` on 2026-11-13, Mac16,7, arm64, 24 GB, macOS 27.0.1, Apple Swift 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1).
Measured commit: `46610dd9c5ab657b66ea119fa20ca945731759c6`, dirty=false.
Accessibility and Screen Recording were granted to the Cursor worker (`node`) and `python3.14` before this run.
Raw JSON: `/tmp/pinchos-129/measure-clean.json`.

| Profile | `phys_footprint` | CPU (`ps`) | `idlew` (60s window) | Numeric FDs | Threads | Children at sample | Descendants at SIGTERM | Leftover after SIGTERM | Compact menu open (median of 3) |
|---|---|---|---|---|---|---|---|---|---|
| P1 three-item / 60s | 11.38-11.39 MB (11928320, 11944704, 11944704) | 0.0% | 0 | 7 | 5 | 0 | 0 | 0 | 18.7 ms (11.0, 18.7, 33.2) |
| five-item mixed (in-flight `sleep 120`) | 12.13 MB (12714752, 12714752, 12714752) | 0.8-1.7% | 1 | 11 | 9 | 2 | 3 | 0 | 32.3 ms (30.4, 32.3, 39.8) |

The P1 three-item reference stays under the ratified **< 15 MB** budget.
The five-item mixed workload is characterization only; it also landed under 15 MB on this machine, but that is not a new product threshold.
Five-item CPU is not an idle sample: `sleep 120` is still running, which is required for the descendant cleanup check.
Issue #129 has no ratified millisecond menu-open budget; these compact-menu samples are recorded evidence, not a new threshold.
P1 opened the `42` extra in 18.7 ms median and two Down-arrow events selected `Collapse Pinchos`.
The five-item `42` extra opened in 32.3 ms median.
`menu_titles` is the last of the three opens: that last open listed `Cached: 42` and `Manual: manual-row`.
Direct children at the pre-probe sample were 2.
Recursive descendants were counted once, immediately before SIGTERM, after the menu probe, and were 3.

P1 idle CPU between ticks was 0.0% in `ps` samples after the 15s settle.
The 60s `top` window's second sample also showed 0.1% CPU on P1 and 1.2% on the in-flight five-item profile.
Wakeups are macOS `top` `IDLEW` over a 60s window (`top -l 2 -s 60`): a per-interval idle-wakeup count.
Only the second sample is parsed.
macOS `top` suffixes IDLEW with `+` or `-` to mark a change since the previous sample, not a clipped column.
The probe strips those suffixes and stores the integer.
`IDLEW` is not a process-lifetime cumulative counter and is not a count of all wakeups.
Numeric FDs are `lsof -nP -a -d 0-65535 -p` (not `lsof | wc -l`).
P1 idle has no in-flight child at SIGTERM.
The five-item profile records descendants with recursive `pgrep -P` immediately before SIGTERM (3 pids: session supervisor, shell, `sleep`) and re-checks those pids with `kill -0` afterwards (0 leftover).

Live compact-menu open latency is measured when `AXIsProcessTrusted()` is true.
P1 times the first extras item titled `42`.
The five profile scouts extras titled `42` and times the one whose opened menu contains a `Cached:` row; it exits 1 if none does.
Each sample is the wall time from starting the `AXPress` helper thread until `AXChildren` polling (0.5 ms sleep) sees an `AXMenu` with `AXMenuItem` rows.
That interval includes Accessibility round-trip and polling overhead.
It is not render time and not main-thread construction time.
After the menu appears, the probe posts two Down-arrow events with `CGEventPostToPid`, reads `AXSelectedChildren`, and dismisses with `AXCancel`.
`#129` has no ratified millisecond budget for that path; the recorded number is evidence, not a new product threshold.
In-process tests still prove menu construction returns while a command is blocked on a fifo, and that menu titles stay a small bound independent of retained output.

Completed-cache measurement: ordinary tests show each retained string is capped at 64 KiB, a source can hold two copies (about 2x cap), truncation is reported above the cap, and a later refresh of the same source replaces those strings.
The 8 MiB active `OutputMemoryBudget` returns to zero after collectors deallocate.
No extra eviction bound is present.
