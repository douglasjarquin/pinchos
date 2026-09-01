---
name: customize-pinchos
description: Help users create, review, troubleshoot, and safely change the canonical read-only Pinchos 0.1 TOML configuration.
---

# Customize Pinchos

Use this skill when a user wants to add, edit, review, or troubleshoot a Pinchos menu-bar item.
Invoke it explicitly with `$customize-pinchos` when you want this workflow for a request.

This skill guides an AI agent.
Pinchos does not load skills or recipes at runtime.
Pinchos runs configured shell commands and menu actions with the user's permissions, and those commands are not sandboxed.

The 0.1 contract is intentionally breaking and read-only.
Pinchos never rewrites the user's TOML during normal operation.
Only `run`, `interval`, `timeout`, `format`, `symbol`, `icon`, and `menu` are supported item keys.
The old type/action/info, group, trigger, notification, structured-output, visibility-policy, scheduler, shell, environment, output-bound, error-policy, freshness-policy, config-mutation, and launchd-service syntax is rejected.

## Workflow

1. Find the real configuration with `pinchos config-path`.
2. Read the current configuration before editing it.
3. Preserve unrelated tables and the user's declaration order.
4. Read [references/configuration.md](references/configuration.md) before changing schema fields or commands.
5. Copy the current file into an isolated temporary `XDG_CONFIG_HOME` root before editing it.
6. Start with the smallest read-only command that proves the requested signal.
7. Show the exact command, executable, arguments, paths, environment names, network destinations, and write targets before adding a risky command.
8. Ask for explicit authorization before adding or running a command that changes state, uses credentials, sends data, contacts a private service, or invokes a privileged tool.
9. Run `validate`, `doctor`, and `run <item>` against the staged root before promoting the edit.
10. Apply only the reviewed diff to the live file when its baseline is unchanged, then repeat the checks against the live path.
11. Save the file and confirm the running app reloads the intended path.

Do not recommend embedded secrets, `curl | sh`, remote script execution, `eval`, `sudo`, destructive commands, broad file globs, or commands copied from an untrusted source.
Do not treat `validate` or `doctor` as a security approval.
Do not change unrelated files, services, accounts, or repositories without separate user authorization.

If a request requires a field or behavior outside the reference, stop and explain the boundary instead of inventing a key.
