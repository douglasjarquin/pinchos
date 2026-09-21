# Feature maps

The `verify` block in `VERIFY.md` names this file as the feature-map index.
Each map linked here lists the user-facing scenarios of one area and marks each `automated` (covered by `mise run verify`) or `manual`.
A row's driver column starts with `automated` or `manual`; a scenario id must be unique across maps.

No maps are linked yet.
The automated suite today is `swift test`, which covers the parser, command runner, scheduler, and AppKit-headless lifecycle paths described in `VERIFY.md`'s Scenarios section.
