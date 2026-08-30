# Pinchos recipes

A curated catalog of 50 standalone, copy-pasteable `pinchos.toml` snippets for common menu-bar signals.

Each file under `recipes/*.toml` is one self-contained recipe: valid v1 Pinchos configuration with at least one `[item.<name>]` table, ready to drop into your own config. This catalog is documentation and example configuration — it is not a plugin system, a registry, or a runtime input to the app. Pinchos never reads this directory; nothing here changes what the shipped binary does. See the [main README's config section](../README.md#config) for the schema these recipes use.

The `# Expected output:` comment in each file describes the command's raw output. The website applies that item's `format` once when it renders the theoretical menu bar preview, so keep units or icons that the command itself emits in the expected output and leave display-only decoration to `format`.

The [website recipes page](https://douglasjarquin.github.io/pinchos/recipes/) is generated from this directory at build time, so adding a valid `.toml` file and rebuilding automatically adds it to the searchable explorer.

## Spec decisions

The originating issue ([#16](https://github.com/douglasjarquin/pinchos/issues/16)) deliberately left three choices open. This catalog resolves them as follows:

1. **Initial catalog scope.** The catalog now contains 50 recipes across time, power, system, network, desktop, development, GitHub, cloud, and cluster signals, including recipes that depend on optional third-party CLIs (`quota-axi`, `gh`, `aws`, `brew`, `docker`, `kubectl`, `mise`, `node`, and `tailscale`). Each optional dependency is clearly marked below with an install/source link, and none of the recipes embeds a credential — they read whatever auth each tool already has configured on your machine.
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
| Time | [`date.toml`](date.toml), [`weekday.toml`](weekday.toml), [`timezone.toml`](timezone.toml), [`locale.toml`](locale.toml) | Built-in (`date`, `locale`) | Calendar date, weekday, timezone, and inherited locale |
| System identity | [`hostname.toml`](hostname.toml), [`username.toml`](username.toml), [`os-version.toml`](os-version.toml), [`architecture.toml`](architecture.toml), [`cpu-cores.toml`](cpu-cores.toml) | Built-in | Host, account, macOS version, architecture, and logical core count |
| System health | [`uptime.toml`](uptime.toml), [`disk-free.toml`](disk-free.toml), [`disk-inodes.toml`](disk-inodes.toml), [`process-count.toml`](process-count.toml), [`top-process.toml`](top-process.toml), [`memory-pressure.toml`](memory-pressure.toml), [`load-average.toml`](load-average.toml) | Built-in | Uptime, storage, process, memory, and load snapshots |
| Network signals | [`local-ip.toml`](local-ip.toml), [`dns-server.toml`](dns-server.toml), [`public-ip.toml`](public-ip.toml), [`http-latency.toml`](http-latency.toml), [`tls-expiry.toml`](tls-expiry.toml) | Built-in (`ipconfig`, `scutil`, `curl`, `openssl`) | Local/public addressing, resolver, request latency, and TLS expiry |
| Desktop audio/display | [`audio-volume.toml`](audio-volume.toml), [`audio-muted.toml`](audio-muted.toml), [`display-count.toml`](display-count.toml), [`focus-mode.toml`](focus-mode.toml) | Built-in | Output volume, mute state, display count, and best-effort Focus hint |
| Homebrew | [`brew-outdated.toml`](brew-outdated.toml), [`brew-services.toml`](brew-services.toml) | **Optional**: [`brew`](https://brew.sh/) | Outdated package count and running service count |
| Docker | [`docker-containers.toml`](docker-containers.toml), [`docker-images.toml`](docker-images.toml) | **Optional**: [`docker`](https://docs.docker.com/desktop/) | Running container and local image counts |
| GitHub work | [`github-open-prs.toml`](github-open-prs.toml), [`github-open-issues.toml`](github-open-issues.toml), [`github-actions.toml`](github-actions.toml) | **Optional**: [`gh`](https://cli.github.com/) | Open work and latest Actions status |
| Git worktree | [`git-branch.toml`](git-branch.toml), [`git-status.toml`](git-status.toml), [`git-ahead-behind.toml`](git-ahead-behind.toml) | Built-in (`git`) | Branch, changed-path count, and upstream divergence |
| Toolchains | [`node-version.toml`](node-version.toml), [`swift-version.toml`](swift-version.toml), [`xcode-version.toml`](xcode-version.toml), [`mise-version.toml`](mise-version.toml) | Built-in or optional toolchain | Active Node, Swift, Xcode, and Mise versions |
| Cluster / tailnet | [`kubectl-context.toml`](kubectl-context.toml), [`tailscale-ip.toml`](tailscale-ip.toml) | **Optional**: [`kubectl`](https://kubernetes.io/docs/tasks/tools/) / [`tailscale`](https://tailscale.com/download) | Current Kubernetes context and Tailscale IPv4 |

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
