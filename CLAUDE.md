# Korpora

`ManateeKit` wraps `manatee-open` (the corpus-query engine behind KonText).
`Korpora` is the native AppKit macOS app built on top of it. It was renamed
from Corpora to Korpora, directories included, so the project lives at
`Korpora/Korpora.xcodeproj` with sources in `Korpora/Korpora/` and tests in
`Korpora/KorporaTests/`. Every "Corpora" that meant *the app* is gone;
"Corpora" as the plural of *corpus* — the Settings tab,
`CorporaSettingsViewController`, `compiledCorporaDirectory` — is correct
and should stay.

## Project plan

`docs/project-plan.md` is the living status/handoff document for this
project — read it before starting non-trivial work, and update it as part
of the work rather than after. It covers `ManateeKit`, `Korpora`, and the
`manatee-open` fork.

Project plans and design notes belong in `docs/` inside this repo. Never
write them to `~/.claude/plans/` or another location outside the checkout —
they need to survive across sessions and machines, and code comments cite
them by repo-relative path.

## Division of labor

- **Terminal Claude Code sessions**: engine-layer work (`ManateeKit`/
  `CManatee`/`manatee-open`), tests, AppKit *code* changes, git/PR work,
  planning.
- **Xcode's built-in Claude agent**: building/running `Korpora.app`,
  visual inspection, interactive click-through testing, iterating on
  layout/visual polish — via its `BuildProject`/`RunAllTests`/
  `DeviceInteraction*` tools.

## Repos

- `ManateeKit/`, `Korpora/`, `scripts/` — this repo
  (`github.com/stranak/Korpora`, renamed from `mac-corpora` along with the
  app). The local checkout directory is `korpora/`.
  - **The bundle identifier is deliberately still
    `cz.cuni.mff.ufal.mac-corpora.dev`** and must stay that way: it's a
    live identifier, not a name, and `UserDefaults` is keyed by it.
    Changing it would orphan every stored setting (fonts, colors, query
    history, context widths) and silently reset the app to defaults.
- `manatee-open/` — a separate git checkout, sibling to this repo, not
  nested/submoduled. Must be `stranak/manatee-open`'s
  `macos-arm64-portability` branch, not upstream `czcorpus/manatee-open` —
  see `docs/project-plan.md`'s "Repository state" section for why.
