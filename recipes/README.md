# Pinchos recipes

A curated catalog of standalone, copy-pasteable `pinchos.toml` snippets for common menu-bar signals.

Each file under `recipes/*.toml` is one self-contained recipe: valid v1 Pinchos configuration with at least one `[item.<name>]` table, ready to drop into your own config. This catalog is documentation and example configuration — it is not a plugin system, a registry, or a runtime input to the app. Pinchos never reads this directory; nothing here changes what the shipped binary does. See the [main README's config section](../README.md#config) for the schema these recipes use.

## Spec decisions

The originating issue ([#16](https://github.com/douglasjarquin/pinchos/issues/16)) deliberately left three choices open. This catalog resolves them as follows:

1. **Initial catalog scope.** Ship all nine candidate families from the issue in this first pass, including the three that depend on optional third-party CLIs (`quota-axi`, `gh`, `aws`). Each of those is clearly marked optional below, with an install/source link, and none of them embeds a credential — they read whatever auth each tool already has configured on your machine.
2. **Runtime boundary.** `recipes/` is documentation-only. It does not change `example/pinchos.toml` or the embedded `ExampleConfig.text` used by `pinchos init` and crash recovery; those remain separate, manually maintained artifacts. If a future issue wants `recipes/` to become their source of truth, that is a distinct decision to make deliberately, not a side effect of adding this catalog.
3. **Network recipes.** The HTTP health and network latency recipes use `https://example.com` / `example.com` as a clearly documented placeholder the user must replace with an endpoint they actually own or care about, with explicit timeout bounds on both the underlying tool and the Pinchos item. No recipe requires network access in CI — `Tests/PinchosCoreTests/RecipeCatalogTests.swift` only parses the TOML text, it never runs `curl`, `ping`, `gh`, `aws`, or `quota-axi`.

## Catalog

| Category | File | Built-in or optional | What it shows |
| --- | --- | --- | --- |
| Clock | [`clock.toml`](clock.toml) | Built-in (`date`) | Current local time |
| Battery | [`battery.toml`](battery.toml) | Built-in (`pmset`) | Battery charge percentage |
| Disk / memory / load | [`system-resources.toml`](system-resources.toml) | Built-in (`df`, `vm_stat`, `sysctl`) | Root volume usage, memory pressure, 1-minute load average (3 items) |
| VPN / network | [`vpn-network.toml`](vpn-network.toml) | Built-in (`ifconfig`, `route`) | Default-route interface, heuristic VPN tunnel detection (2 items) |
| Network latency | [`network-latency.toml`](network-latency.toml) | Built-in (`ping`) | Round-trip time to a host you configure |
| HTTP health | [`http-health.toml`](http-health.toml) | Built-in (`curl`) | HTTP status code of an endpoint you configure |
| AI provider quota | [`ai-quota.toml`](ai-quota.toml) | **Optional**: [`quota-axi`](https://github.com/kunchenguid/quota-axi) + [`jq`](https://jqlang.org/) | Remaining weekly quota percentage for a coding-agent provider |
| GitHub status | [`github-status.toml`](github-status.toml) | **Optional**: [`gh`](https://cli.github.com/) | Unread GitHub notification count |
| AWS profile | [`aws-profile.toml`](aws-profile.toml) | **Optional**: [`aws`](https://aws.amazon.com/cli/) | AWS account ID a named CLI profile resolves to |

"Built-in" means the recipe only calls tools that ship in `/bin`, `/usr/bin`, `/usr/sbin`, or `/sbin` on stock macOS. "Optional" recipes name a third-party CLI, its install/source link, and its account or network requirement directly in the file; none of PinchosCore or the AppKit target gained any dependency on these tools — `run` is still just a shell command string.

Every recipe documents, in its own header comment: purpose, item name(s), the command and why it's shaped that way, interval/timeout/other relevant settings, an expected output example (and whether that output is locale-, account-, network-, or machine-dependent), macOS/tool assumptions, external dependencies with install links, and known limitations (including what happens when a dependency is missing).

## Using a recipe

1. **Copy.** Open a recipe file and copy its `[item.*]` table(s) — and, if present, its `[item.<name>.env]` table — into your `pinchos.toml`. Find your config path with:

   ```sh
   .build/release/pinchos config-path
   ```

   (Or `pinchos init` first, if you don't have a config yet.)

2. **Validate.** Confirm the merged file still parses and every field is within the v1 schema:

   ```sh
   .build/release/pinchos validate
   ```

3. **Diagnose.** Check that the item's shell, working directory, icon (none of these recipes set one), and — for simple, non-piped commands — the command itself are all resolvable:

   ```sh
   .build/release/pinchos doctor
   ```

   Recipes whose `run` line is a shell pipeline (uses `|`) make `doctor` report that it "could not identify a single command to check safely" for that line. That is expected: [`Sources/pinchos/PinchosCLI.swift`](../Sources/pinchos/PinchosCLI.swift) intentionally declines to guess at a command hidden inside a compound pipeline rather than risk checking the wrong thing. Each such recipe calls this out in its own comments.

4. **Run.** Execute the item once, outside the menu bar, to see its real output and exit code:

   ```sh
   .build/release/pinchos run <item-name>
   ```

5. **Reload.** If Pinchos is already running, it live-reloads on save — no relaunch needed.

## Verification notes

- Every recipe is enumerated and parsed by `Tests/PinchosCoreTests/RecipeCatalogTests.swift`, which mirrors the existing `example/pinchos.toml` coverage in `Tests/PinchosCoreTests/ConfigParserTests.swift`. That test runs offline in CI as part of `swift test` and fails if a recipe becomes malformed or uses a field outside the current v1 schema.
- Built-in recipes (clock, battery, system-resources, vpn-network) were verified by running their exact `run` command directly in a macOS Terminal and confirming the documented output shape.
- Network- and account-dependent recipes (network-latency, http-health, ai-quota, github-status, aws-profile) are syntax-checked only in this repository; each file's comments state its dependency, account/network requirement, and documented failure behavior so you can verify it live once that dependency is installed or configured.
- No recipe sets `icon` or `working_directory`, so none of them assumes a filesystem layout beyond wherever you paste them.
