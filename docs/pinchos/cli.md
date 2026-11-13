# CLI

`init`, `validate`, `doctor`, `run`, `config-path`, and `open-config`. Moved out of the README.

```sh
.build/release/pinchos init
.build/release/pinchos validate
.build/release/pinchos doctor
.build/release/pinchos run codex
```

`init` creates the resolved configuration directory and writes the checked-in example only when no configuration exists.
`validate` parses the file without running commands.
`doctor` is a fresh CLI inspection, not a live GUI cache snapshot.
It prints the resolved config path and, when available, version and install path.
It checks primary sources, dynamic menu sources, and actions against the shared execution policy without running them.
A compound shell expression that cannot be inspected safely is reported as unknown, not missing.
Unquoted `~/` paths expand against HOME.
An unterminated quote or trailing backslash is a counted failure.
Missing tools and unreadable icons include a short next step.
Doctor does not dump the inherited environment, credential metadata, or login-item state.
`run <item>` executes one item for scriptable verification under that same policy.
`config-path` prints the resolved path and `open-config` opens it in the default application.

The execution policy is documented in [runtime.md](runtime.md).
PATH is `/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`.
`SSH_AUTH_SOCK` is not inherited.
