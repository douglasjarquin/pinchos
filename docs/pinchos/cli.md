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
`doctor` checks the configured command and icon prerequisites against the shared execution policy without running the command or dumping the inherited environment.
`run <item>` executes one item for scriptable verification under that same policy.
`config-path` prints the resolved path and `open-config` opens it in the default application.

The execution policy (PATH, HOME, working directory, inherited keys) is documented in [runtime.md](runtime.md).
