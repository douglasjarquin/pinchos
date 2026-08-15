# Code-quality review: pinchos issue #5

Range: `b4c8c78ab5870aa2a3d1ac8839cae3c68b9a67bb..12cc84536b6cab5a1bb4e7d0fa193f5f86cad824`

Review mode: source-only.
No build, test, application launch, pipeline, PR, or external checkout inspection was performed.

## Conclusion

`codeQualityStatus`: WATCH

`recommendation`: APPROVE

The command runner correctly coordinates EventRace, process-group claims, concurrent drain ownership, actor reentrancy, parser bounds, and AppKit projection for the stated behavior.
Natural-exit descendants deliberately remain owned until cancellation or the original timeout, so their primary execution correctly remains an `.exited` result.

## CRITICAL

None.

## HIGH

None.

## MEDIUM

1. **Command pipes can leak into a simultaneously spawned command, contaminating drain lifetime.**
   `Sources/PinchosCore/CommandExecution.swift:347-371` creates ordinary pipes and passes their descriptors through `posix_spawn`; no endpoint receives `FD_CLOEXEC` before another runner can spawn.
   While one invocation is between pipe creation and the parent close at lines 386-389, a different per-item runner can inherit its write endpoints.
   That unrelated process can keep the first command's stdout/stderr pipe open after its shell exits, delaying EOF and causing the first command to fall back to the 300 ms drain stop at lines 605-634.
   This loses late diagnostics and creates cross-item descriptor/resource coupling.
   Remediate by creating both pipes close-on-exec (or applying `F_SETFD, FD_CLOEXEC` to all four ends before any await/spawn boundary), while retaining the `dup2` file actions for the intended child stdout/stderr descriptors.

2. **The runner's concurrency/lifecycle implementation is an oversized single module, making future race fixes unsafe.**
   `Sources/PinchosCore/CommandExecution.swift:255-709` combines process spawning, pipe ownership, blocking I/O bridges, event racing, timeout arbitration, output retention, and signal lifecycle in one 455-line type; the file has 764 nonblank/noncomment lines overall.
   The seven follow-up race/lifecycle commits in this exact range show that these responsibilities are tightly coupled in practice.
   Remediate by separating the POSIX process-and-pipe session from the event/timeout race and from the actor-facing retained-session state, preserving the current public `CommandRunner` API.

## LOW

None.

## Skill-perspective check

The required `omo:remove-ai-slops` and `omo:programming` skills were loaded and applied before judging maintainability and test relevance.
`remove-ai-slops` is violated by the oversized production module above.
No separate applicable `programming` violation was found: this is Swift, for which that skill provides no language-specific reference; its applicable shared criteria found no untyped escape hatch, brittle prompt test, implementation-mirroring test, or unnecessary parser/validation layer.
The new tests exercise observable real-process behavior and do not merely assert a requested removal or mirror implementation constants.

## Blockers

None.
