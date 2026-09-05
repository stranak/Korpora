# mac-corpora

`ManateeKit` wraps `manatee-open` (the corpus-query engine behind KonText).
`Corpora` is the native AppKit macOS app built on top of it.

## Project plan

`docs/project-plan.md` is the living status/handoff document for this
project — read it before starting non-trivial work, and update it as part
of the work rather than after. It covers `ManateeKit`, `Corpora`, and the
`manatee-open` fork.

Project plans and design notes belong in `docs/` inside this repo. Never
write them to `~/.claude/plans/` or another location outside the checkout —
they need to survive across sessions and machines, and code comments cite
them by repo-relative path.

## Division of labor

- **Terminal Claude Code sessions**: engine-layer work (`ManateeKit`/
  `CManatee`/`manatee-open`), tests, AppKit *code* changes, git/PR work,
  planning.
- **Xcode's built-in Claude agent**: building/running `Corpora.app`,
  visual inspection, interactive click-through testing, iterating on
  layout/visual polish — via its `BuildProject`/`RunAllTests`/
  `DeviceInteraction*` tools.

## Repos

- `ManateeKit/`, `Corpora/`, `scripts/` — this repo
  (`github.com/stranak/mac-corpora`).
- `manatee-open/` — a separate git checkout, sibling to this repo, not
  nested/submoduled. Must be `stranak/manatee-open`'s
  `macos-arm64-portability` branch, not upstream `czcorpus/manatee-open` —
  see `docs/project-plan.md`'s "Repository state" section for why.
