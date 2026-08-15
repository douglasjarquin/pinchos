# Security review: issue #5 command execution

Scope: source-only audit of `b4c8c78ab5870aa2a3d1ac8839cae3c68b9a67bb..12cc84536b6cab5a1bb4e7d0fa193f5f86cad824`.
No tests, build, application launch, pipeline action, or source change was performed.

## CRITICAL

None.

## HIGH

- `Sources/PinchosCore/CommandExecution.swift:192-193` and `Sources/PinchosCore/CommandExecution.swift:214-215` retain only a numeric process-group ID and later use it both as a liveness check and a `SIGTERM`/`SIGKILL` target.
  After the original group exits, that ID can be recycled to an unrelated process group.
  `kill(-processGroupID, 0)` then reports that unrelated group as live, and item removal or app shutdown signals it.
  This can terminate unrelated same-user processes.

- `Sources/PinchosCore/ByteCount.swift:23-33` accepts every positive non-overflowing `Int` value for `max_output`.
  `OutputCollector` uses that value as its retained-data bound (`Sources/PinchosCore/CommandExecution.swift:72-89`), so a hostile or erroneous configuration such as a multi-gigabyte value lets a command's stdout and stderr exhaust application memory.
  This defeats the authoritative bounded-output requirement.

## MEDIUM

None.

## LOW

None.

## Deliberate behavior reviewed

- Executing the configured `run`/`click` text through `/bin/sh -c` at `Sources/PinchosCore/CommandExecution.swift:514-552` is deliberate configuration-defined command execution, not a new injection path.
- Inheriting the parent environment at `Sources/PinchosCore/CommandExecution.swift:526-547` and exposing a bounded stderr diagnostic at `Sources/pinchos/StatusItemController.swift:132-134` do not add a distinct privilege boundary in this local, user-owned configuration model.

## Skill-perspective check

The `remove-ai-slops` and `programming` perspectives were consulted before review.
Neither adds a separate violation within this security-only scope; the uncapped `max_output` is nevertheless a concrete resource-boundary failure.
The security-diff-scan preflight helper was unavailable because the provided `python3` lacks both `tomllib` and `tomli`; manual source-only coverage was completed.

## Result

`codeQualityStatus`: BLOCK

`recommendation`: REQUEST_CHANGES

`blockers`:

- Prevent PID/process-group identifier reuse from directing cancellation signals to an unrelated group.
- Enforce a finite, safe upper bound for parsed `max_output` values.
