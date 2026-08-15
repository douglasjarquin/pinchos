# Issue 5 gate review

recommendation: REJECT

## originalIntent

Implement issue #5 as bounded and cancellable PinchosCore command execution with concurrent stdout and stderr draining, per-item timeout and retained-output bounds, process-group cleanup on timeout, item removal, reload, and app exit, diagnostics projected by AppKit, tests and documentation, and delivery as an open unmerged PR whose body physically contains `Closes #5`.

## desiredOutcome

Users can configure safe command limits, receive bounded output and useful diagnostics, reload or quit without leaving managed descendants alive, and review the completed change in an open unmerged issue-closing PR.

## userOutcomeReview

The checked source implements the requested runtime behavior. Timeout and cancellation race against `waitpid`, kill the spawned process group, and preserve bounded output (`Sources/PinchosCore/CommandExecution.swift:315-488`). Natural parent exit retains same-group descendants and drains until they exit, are cancelled, or reach the original timeout (`Sources/PinchosCore/CommandExecution.swift:449-488`, `Sources/PinchosCore/CommandExecution.swift:729-823`). Reload and shutdown await each item's runner and click-runner cancellation before removing status items (`Sources/pinchos/ManagedItem.swift:52-60`, `Sources/pinchos/StatusItemController.swift:55-75`), and app termination waits for shutdown before replying (`Sources/pinchos/AppDelegate.swift:42-52`). Diagnostics are a presentation-only projection of the core snapshot (`Sources/pinchos/StatusItemController.swift:112-162`). Configuration and docs expose matching timeout and per-stream retained-tail limits (`Sources/PinchosCore/ConfigParser.swift:60-102`, `README.md:61-87`).

The requested delivery outcome is not source-verifiable. No PR body, PR metadata capture, or other checked artifact proves that target `12cc84536b6cab5a1bb4e7d0fa193f5f86cad824` is on an open unmerged PR with a physical `Closes #5` line. Local history only proves the branch name and commits; commit messages contain no `Closes #5` line.

## blockers

- violatedCriterion: DELIVERY-PR
  observation: Required open unmerged PR and physical `Closes #5` line are not proven by any allowed artifact.
  evidencePointer: missing PR metadata/body artifact; `git log b4c8c78ab5870aa2a3d1ac8839cae3c68b9a67bb..12cc84536b6cab5a1bb4e7d0fa193f5f86cad824` contains no `Closes #5`; local branch `codex/issue-5-bound-observe-command-execution` points at target but does not establish PR state or body.

## notes

- No source-verifiable runtime blocker found for timeout, active cancellation, natural-exit descendants, reload, app exit, diagnostics, or output boundaries.
- The process implementation is 830 lines and exceeds the remove-ai-slops module-size guideline, but this is a NOTE because no stated success criterion imposes a size limit. The implementation has distinct low-level spawn, drain, process-group, race, result, and actor responsibilities, so maintenance burden is real even though it does not block this gate.
- Tests use wall-clock sleeps and polling (`Tests/PinchosCoreTests/CommandExecutionTests.swift:172-175`, `Tests/PinchosCoreTests/CommandExecutionTests.swift:193-197`, `Tests/PinchosCoreTests/CommandExecutionTests.swift:214-218`, `Tests/PinchosCoreTests/CommandRunnerTests.swift:50-58`). This is a determinism risk under the programming/slop criteria, but it does not prove failure of a stated criterion.
- No deletion-only, requested-removal-only, tautological, or production-implementation-mirroring test was found. The tests exercise real subprocess effects and observable outputs. The late-stderr test is behavior-bearing, not deletion-only.
- `ConfigParser` repeats default literals instead of using `ItemConfig.defaultTimeout` and `ItemConfig.defaultMaxOutputBytes` (`Sources/PinchosCore/ConfigParser.swift:67-68`, `Sources/PinchosCore/ConfigParser.swift:83-84`; constants at `Sources/PinchosCore/ItemConfig.swift:4-5`). This is minor duplication, not a criterion failure.

## checkedArtifacts

- Review range `b4c8c78ab5870aa2a3d1ac8839cae3c68b9a67bb..12cc84536b6cab5a1bb4e7d0fa193f5f86cad824`
- `Sources/PinchosCore/CommandExecution.swift`
- `Sources/PinchosCore/ByteCount.swift`
- `Sources/PinchosCore/ItemConfig.swift`
- `Sources/PinchosCore/ConfigParser.swift`
- `Sources/pinchos/AppDelegate.swift`
- `Sources/pinchos/ManagedItem.swift`
- `Sources/pinchos/StatusItemController.swift`
- changed PinchosCore tests
- `README.md`
- `example/pinchos.toml`
- commit history in the review range
- `.omo/` was absent before this report; therefore no plan, executor report, code-review report, manual-QA matrix, or notepad artifact was available to validate.

## exactEvidenceGaps

- PR URL or immutable PR metadata tying target SHA `12cc84536b6cab5a1bb4e7d0fa193f5f86cad824` to an open, unmerged PR.
- PR body artifact showing the exact physical line `Closes #5`.
- No supplied executor evidence, code-review report, manual-QA matrix, or notepad path. Their absence does not independently block because the direct source pass supports the runtime criteria.

## reviewConstraints

Source-only. No build, tests, app launch, browser, network PR lookup, pipeline operation, commit, push, or PR mutation was performed.
