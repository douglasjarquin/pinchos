# Flywheel ledger

Append-only record of flywheel runs for this repository.
Do not re-propose a target marked rejected.

| date | run | summary | verdicts | files |
| --- | --- | --- | --- | --- |
| 2026-11-04 | factcheck (flywheel-fact-check-202610310822) | Sampled 40 public claims (platform, install/Homebrew, CLI, sandbox, license, release, menu-open, NSStatusItem/dock, example URLs/commands, preview TOML, remainder checksums, recipe count, skills paths). | 3 wrong (canonical preview lists a static row it does not have; menu-open copy said commands never start; performance doc attributed the 15MB/idle-CPU budget to README). 37 verified. No unsupported claims left unfixed in the sample. | README.md; docs/pinchos/configuration.md; docs/performance.md; site/DESIGN.md; site/src/pages/index.astro; site/src/pages/design-system/index.astro; site/src/components/InteractiveMenuBar.astro; site/src/components/ProductMockup.astro; .flywheel/ledger.md |
| 2026-11-18 | factcheck (flywheel-fact-check-202610310822) | Sampled 40 public claims changed since a35696c8 (clock init, PATH/SSH_AUTH_SOCK, CLI/defaults, 30s retry, Refresh Now, 13.8MB P1, macOS 14/arm64, macos-26 CI, installer fail-closed, remainder archive digest, VoiceOver, menu footer). Live site matched main. Ledger had no due recheck dates. | 3 wrong (skill/recipe/runtime copy still said menu construction never executes a command). 37 verified. No unsupported claims left unfixed in the sample. | skills/customize-pinchos/references/configuration.md; recipes/README.md; docs/pinchos/runtime.md; .flywheel/ledger.md |
