# CLI

`init`, `validate`, `doctor`, `run`, `config-path`, and `open-config`.

Build the release executable first (`swift build -c release`).
The commands below are `.build/release/pinchos`.
`--help` and `-h` work on every subcommand and print usage without running it.

## Config path

Pinchos reads `$XDG_CONFIG_HOME/pinchos/pinchos.toml` when `XDG_CONFIG_HOME` is non-empty.
Otherwise it reads `~/.config/pinchos/pinchos.toml`.

```sh
.build/release/pinchos config-path
```

`config-path` prints the resolved file and creates nothing.

## First run

```sh
.build/release/pinchos config-path
.build/release/pinchos init
.build/release/pinchos validate
.build/release/pinchos open-config
```

`init` creates the resolved configuration directory and writes the checked-in example only when no configuration exists.
A second `init` prints `Config already exists` and leaves the file unchanged.
`validate` parses the file without running commands and without writing.
`open-config` opens the same path in the default application.
If the file is missing, `open-config` creates an empty file and then opens it.
It does not overwrite an existing file.

`.build/release/pinchos doctor` is a fresh CLI inspection, not a live GUI cache snapshot.
It prints the resolved config path and, when available, version and install path.
It checks primary sources, dynamic menu sources, and actions against the shared execution policy without running them.
A compound shell expression that cannot be inspected safely is reported as unknown, not missing.
Unquoted `~/` paths expand against HOME.
An unterminated quote or trailing backslash is a counted failure.
Missing tools and unreadable icons include a short next step.
Doctor does not dump the inherited environment, credential metadata, or login-item state.

`run <item>` executes one item for scriptable verification under that same policy.
The checked-in example item is `codex` and needs Remainder on the fixed PATH or an absolute path; see [example-setup.md](example-setup.md).

Run `.build/release/pinchos` with no arguments to launch the menu-bar app; any argument goes to the CLI.
That no-argument launch runs in the foreground and keeps the terminal busy until the app quits, so it has not hung.
Stop it with Quit Pinchos from its menu (Quit in the recovery menu), or Ctrl-C in the launching terminal.

```sh
.build/release/pinchos
```

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success, including `init` when the file already exists |
| 2 | Usage error (unknown command or extra arguments) |
| 3 | Config, parse, or open error, including `config contains no items` |
| 4 | Doctor found one or more problems |
| 124 | `run` timed out |
| 125 | `run` skipped, cancelled, or otherwise failed to execute |
| 127 | `run` failed to launch |

`--help`/`-h` exits 0.
For `run`, any other command exit code is returned capped at 255.
A signal-terminated `run` command returns `min(255, 128+signal)`.
An item's own exit code passes through unchanged, so it can collide with Pinchos's reserved 2/3/4/124/125/127.

## Recover from a malformed file

`validate`, `doctor`, `run`, and `init` never delete or rewrite an existing config.

1. Run `.build/release/pinchos validate` to print the parse error.
2. Open the existing file with `.build/release/pinchos open-config` or an editor.
3. Do not run `init` expecting a reset: it refuses to overwrite.
4. Repair the file, then `.build/release/pinchos validate` again.
5. If the menu-bar app is running, it kept the last known-good items.
   Use Reload from the recovery menu, or save a valid file and let the watcher apply it.

The GUI recovery menu offers Open Config, Open Config Directory, Reload, and Quit.
Create Example Config appears only when the file is missing.
Details are in [runtime.md](runtime.md).

The execution policy is documented in [runtime.md](runtime.md).
PATH is `/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`.
`SSH_AUTH_SOCK` is not inherited.
Commands and actions are unsandboxed code executed with the user's permissions.
