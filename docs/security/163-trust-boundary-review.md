# Trust-boundary review (#163)

Reviewed revision: `a84034d` (main, November 17, 2026).
Fixes land in the PR that adds this file; regression tests are named below.
Scope and boundary are those of issue #163: no sandbox, no provider testing, and no signing workflow (that is #15).

## Inputs and trust boundaries

| Input | Who controls it | Trust |
| --- | --- | --- |
| `pinchos.toml` at `$XDG_CONFIG_HOME/pinchos/` or `~/.config/pinchos/` | The user | Trusted: every `run`/`action` is user-authorized, unsandboxed code |
| Command stdout/stderr | The configured command and whatever it reads (network, files) | Untrusted text: bounded, sanitized before display |
| Host environment and descriptors of the app or CLI | launchd, Terminal, the parent shell | Not passed through except the documented key set |
| Menu clicks | The user, against a menu built from one config generation | Must act only on that generation |
| Release zip and `.sha256` sidecar | GitHub release assets or `PINCHOS_BASE_URL` | Untrusted until checksum, Developer ID, and Gatekeeper pass |
| Cask `sha256` | This repository | Trusted pin |

A configured command running with the user's permissions is the product's documented capability, not a finding.
Findings below are places where something other than the configured command ran, received data, or was trusted.

## Findings

| # | Severity | Finding | Disposition |
| --- | --- | --- | --- |
| 1 | Medium | Commands and the supervisor inherited the host's stdin and every descriptor not marked close-on-exec | Fixed |
| 2 | Medium | A menu left open across a reload could run a different command than the row clicked, or Refresh Now could request sources the reload swapped in | Fixed |
| 3 | Medium | `install.sh` checksum step could pass without checking the zip | Fixed (byte-exact) |
| 4 | Medium | `install.sh` accepts any notarized Developer ID, not the Pinchos team | Follow-up #207, needs the #15 identity |
| 5 | Low | Docs did not say that command text is visible in `ps` or where output can surface | Fixed (docs) |
| 6 | Low | No ownership/permission check on the config file | Accepted |

### 1. Descriptor and stdin inheritance

Both `posix_spawn` calls (command and supervisor) used default inheritance.
The command received the app's stdin, which is the user's terminal under `pinchos run`, plus any descriptor without `FD_CLOEXEC`: the GUI's config-watcher descriptor (`open(O_EVTONLY)`), and, during the window between `pipe()` and `fcntl(FD_CLOEXEC)`, another concurrently launching command's output pipes.
A leaked pipe write end delays that other command's EOF until the leaking command exits.

Reproduction on `a84034d`: `pinchos run fds 7</etc/hosts` with `run = "ls -l /dev/fd/"` listed descriptor 0 as `/etc/hosts` and descriptor 7.
Fix: `POSIX_SPAWN_CLOEXEC_DEFAULT` on both spawns, stdin opened as `/dev/null`, and `O_CLOEXEC` on the watcher descriptor.
Regression: `CommandExecutionTests.testCommandInheritsOnlyDevNullStdinAndItsOwnOutputPipes` fails on `a84034d` (`leaked`) and passes with the fix.

### 2. Stale menu targets

A menu row captured only `(item, index)`, and Refresh Now captured only the item.
An item update that changes its rows replaces every row runner but keeps the same `ManagedItem`, so a row clicked in a menu built before the reload ran whatever action now sat at that index.
AppKit keeps servicing the main queue while a menu is open, so a reload (for example an editor save or a dotfiles sync) can commit during tracking.

Reproduction on `a84034d`: rows `Deploy, Wipe` reordered to `Wipe, Deploy`; invoking index 0 as the old menu would ran `Wipe`.
Fix: the menu captures the row's runner as a token and `invokeMenuRow(at:expecting:)` runs only when it is still the live runner for that index.
Unchanged rows keep their runners, so menus stay usable across reloads that do not touch them.
Refresh Now likewise captures a token for the item's value sources; a commit that replaces the primary source or changes the menu rows replaces it, and `refreshNow(expecting:)` checks it when the click is dispatched.
A reload that changes only presentation (for example `format`) keeps the token.
Regressions: `ManagedItemLifecycleTests.testStaleMenuRowTokenDoesNotRunTheRowThatNowOccupiesItsIndex`, and `StaleMenuTargetTests`, which sends the actual `NSMenuItem` actions built by `StatusItemController` for a real `ManagedItem` across a reload and checks that a menu built afterwards works.
Removing the Refresh Now token check makes the stale-refresh test run the new primary and row commands.
Retired items offer neither token.
The existing held-action tests still cover the accept-then-replace race.

### 3. Checksum sidecar bypass

`shasum -a 256 -c` verifies whichever file the downloaded sidecar names.
A sidecar of `<digest of /bin/ls>  /bin/ls` printed `/bin/ls: OK` and the script continued with an unchecked zip.
Signature and Gatekeeper checks still ran, so this weakened the checksum gate rather than bypassing installation verification as a whole.
Fix: the script rebuilds the one line `shasum -a 256 <zip>` would print from the sidecar's first 64 bytes and compares it with the sidecar using `cmp`, so NUL bytes, a missing final newline, CRLF, and extra lines are rejected rather than normalized away by command substitution; it then compares that digest with `shasum -a 256` of the downloaded zip.
Regression: `InstallScriptTests` (other-file, empty, two-line, binary-marker, path-prefixed, uppercase, missing-terminator, trailing-blank-line, CRLF, embedded-NUL, and mismatched sidecars; a valid checksum on an unsigned bundle still fails at the signature gate and installs nothing).
Three of its four tests fail on `a84034d`; the mismatch case already failed closed there and only the message differs.
The first fix (`070b134`) still accepted the missing-terminator, blank-line, and both NUL variants.

### 4. Developer ID team not pinned

`codesign -dvv | grep "Authority=Developer ID Application:"` plus `spctl --assess` accept any notarized developer.
With replaced release assets, another team's notarized app named `Pinchos.app` would install and its CLI would be executed by the smoke check.
Pinning needs the real Team ID that #15 establishes, so it is tracked in #207 together with rejecting a symlinked `Pinchos.app`.

### 5. Secret handling documentation

`run` text is the `/bin/sh -c` argument, readable by other local users through `ps` while it runs, and is stored in plain text in the TOML.
Command output can surface in menu previews, diagnostics, `pinchos run`, and on the pasteboard via the explicit Copy actions.
`docs/pinchos/runtime.md#secrets-and-command-output` now says this and recommends reading secrets at run time from the Keychain or a private file.

### 6. Config file permissions

Pinchos does not refuse a config that other users can write.
On a single-user Mac the config lives in the user's home directory; adding a permission policy is the kind of new framework #163 excludes.
Accepted; revisit if Pinchos ever runs with a shared or system config path.

## Independent review dispositions

The independent review of `070b134` raised five findings.

| # | Finding | Disposition |
| --- | --- | --- |
| R1 (blocking) | Refresh Now from a menu built before a reload requested the replacement sources | Fixed; see finding 2 |
| R2 | The sidecar check validated text after command substitution normalized it | Fixed; see finding 3 |
| R3 | Option-click diagnostics can subscript rows a reload replaced while the builder awaits a snapshot (pre-existing) | Follow-up #209 |
| R4 | Supervisor pipe setup leaked the first pipe if the second allocation failed, and could close child-side descriptors twice after a late failure (pre-existing) | Fixed: `OwnedDescriptors` gives each pipe end one owner from allocation to hand-off or unwind; `CommandExecutionTests.testSupervisorLaunchClosesFirstPipeWhenSecondAllocationFails` injects the second allocation failure |
| R5 | `install.sh` deletes the previous app before the CLI smoke check | Follow-up #210, tracked with #15 |

## Reviewed without findings

- Config path and reload: resolution is environment-only (`ConfigLocation`), `init` and the recovery action create with `.withoutOverwriting`, malformed config keeps the last known-good items, and `ConfigWatcher` generations make stale watch callbacks no-ops.
- Environment: only the documented keys are inherited; `SSH_AUTH_SOCK` and arbitrary secrets are not (`CommandExecutionTests.testSSHAuthSockIsNotPassedThroughToSpawnedCommands`).
- Process ownership: each execution has its own process group led by the supervisor; `requestTermination` signals the group only while the supervisor is unreaped, under the same lock as the reaper, so a recycled group ID is never signalled.
- SIGPIPE: the only app-written pipe (supervisor control) has `F_SETNOSIGPIPE`.
- Output: per-stream ring buffers under one 8MiB process-wide budget; previews are bounded and escape control characters; nothing is logged or written to disk; the only stderr diagnostic names the item, not its command.
- Doctor: prints check results without command text, environment, or output (verified with a synthetic bearer token in `run`).
- Install: staged copy beside the target and same-volume swap, the user config is never touched, and the cask placeholder digest fails closed until #15 publishes.
