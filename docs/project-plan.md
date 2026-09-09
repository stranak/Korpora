# Korpora: native AppKit corpus concordancer — status & handoff

This is the living status/handoff document for this project. It lives at
`docs/project-plan.md` in the repo (not `~/.claude/plans/` or anywhere
outside the checkout) so any session — Terminal or Xcode — can read and
update it, and so code comments can cite it by a stable path. See the root
`CLAUDE.md` for the convention.

**Naming (2026-09-08)**: the Xcode project/app was renamed from Corpora to
Korpora on GitHub — product name, scheme, target names, `NSDocumentClass`/
UTI, and the `CorporaDocumentController` class (→
`KorporaDocumentController`) all follow. In a second pass the same day the
app directory followed too (`Corpora/` → `Korpora/`), as did the
Application Support directory and the compiled-corpora environment
variable:

| Was | Is |
| --- | --- |
| `Corpora/Korpora.xcodeproj` | `Korpora/Korpora.xcodeproj` |
| `Corpora/Corpora/` (app sources) | `Korpora/Korpora/` |
| `Corpora/CorporaTests/` | `Korpora/KorporaTests/` |
| `CORPORA_COMPILED_CORPORA_DIRECTORY` | `KORPORA_COMPILED_CORPORA_DIRECTORY` |
| `~/Library/Application Support/Corpora/` | `~/Library/Application Support/Korpora/` |

The GitHub repo followed too (`stranak/mac-corpora` → `stranak/Korpora`);
the local checkout directory is `korpora/`.

So every "Corpora" that meant *the app* is now "Korpora". "Corpora" as the
plural of *corpus* is correct and stays — the Settings tab,
`CorporaSettingsViewController`, `AppSettings.compiledCorporaDirectory`,
`reloadCorpora()`. `project.yml` points `sources:`/`INFOPLIST_FILE`/
`CODE_SIGN_ENTITLEMENTS` at the renamed directories; re-run `xcodegen
generate` in `Korpora/` after any further move.

**Two things deliberately keep an old name — do not "finish the rename"
by changing either:**

- `PRODUCT_BUNDLE_IDENTIFIER = cz.cuni.mff.ufal.mac-corpora.dev`
  (`project.yml` and the generated `project.pbxproj`). It's a live
  identifier, not a name: `UserDefaults` is keyed by bundle id, so
  changing it orphans every stored setting — fonts, colors, query history,
  context widths, `allowMultipleExtendedContexts` — and the app silently
  comes up with defaults. Also worth noting the `.dev` suffix: this
  identifier was never meant to be the shipping one anyway.
- `ExtendedContextDisplayMode.sheet`, whose raw value persists in
  `UserDefaults` even though it has presented a plain window since 6.6's
  follow-up. Same reasoning; the Settings UI labels it "Window" instead.

Two things broke on the directory rename, and both are *baked-in absolute
paths* — the one category no source-level rename can catch:

- `Korpora/DevCorpus/registry/testcorp` holds an absolute `PATH` written at
  generation time. After the move it pointed at the old directory and
  Manatee threw while opening the lexicon. Fix: re-run
  `Korpora/scripts/build-dev-corpus.sh` (it derives paths from its own
  location, and is safe to re-run).
- Registry files under Application Support have the same baked-in `PATH`,
  so moving that directory is not just a `mv` — each registry file's `PATH`
  has to be rewritten too. (Their `VERTICAL` lines are provenance only;
  a stale one doesn't stop the corpus from opening.)

That throw should have been a corpus-picker error message, but it
**`abort()`ed the whole app** instead — and took the test host with it, so
all 35 `KorporaTests` reported "not run" rather than failing. Root cause:
`mtc_corpus_size` had no `try`/`catch`, so a C++ exception unwound across
`mtcbridge.cc`'s `extern "C"` boundary, which is UB and in practice
`std::terminate()`. Fixed 2026-09-08:

- **`mtcbridge.cc` now states the boundary rule as an invariant**: no
  exception may cross it. Entry points either take a `char **error` and
  report via `set_error`, or wrap their body in the new `guard`/
  `guard_void` helpers and return their existing null-handle sentinel. 23
  previously unguarded entry points were wrapped. A sentinel means
  "failed", never a real value.
- **`mtc_corpus_size` gained a `char **error` out-param**, so Manatee's
  actual diagnostic survives instead of being flattened to `-1`. It reads
  like a cheap accessor but is the call that first opens compiled data off
  disk (`search_size()` → `size()` → `get_default_attr()`), which is why a
  corpus that opened fine can still fail here — opening only parses the
  registry *file*.
- **`Corpus.size` and `Corpus.info()` now `throw`.** `info()`'s doc comment
  had claimed the whole call did no engine work, which is what hid this:
  it reads `sizeTokens` from `size`. The picker's existing `catch` already
  renders the message, so a bad corpus now shows
  `FileAccessError (…) in failed to open FSA lexicon [No such file or
  directory]` in the info label.
- Regression test: `CorpusInfoTests.testSizeThrowsWhenRegistryPathDoesNotResolve`
  builds a registry whose `PATH` doesn't resolve and asserts both `size`
  and `info()` throw. Verified end-to-end by re-breaking
  `DevCorpus/registry/testcorp` and confirming the app stays running with
  no crash report, where it previously aborted on launch.

Also fixed while there: `mtc_colloc_get_item`/`_freq`/`_cnt` dereferenced
`items` with no null check, unlike their `get_bgr` sibling.

Everything **below** this note was written before the rename and still
says "Corpora" throughout — read those mentions as "Korpora."

## Division of labor

- **Terminal Claude Code sessions**: engine-layer work (`ManateeKit`/
  `CManatee`/`manatee-open`), XCTest, AppKit *code* changes, git/PR work,
  planning.
- **Xcode's built-in Claude agent**: building/running `Corpora.app` via
  `BuildProject`/`RunAllTests`/`RunProject`, and — for anything that
  actually needs a screen — `RenderPreview` for SwiftUI-only work.
  **Correction (2026-09-05): `DeviceInteraction*` (the synthesize
  screenshot/click/type tool) only supports iOS/watchOS/tvOS
  *simulators*, not macOS app windows** — confirmed by trying it against
  this project's `Corpora` scheme, which was rejected outright
  ("device... not supported for Device Interaction"). There is currently
  **no tool available to either session type that can click through
  `Corpora`'s AppKit UI.** `BuildProject`/`RunAllTests`/`RunProject` +
  `GetConsoleOutput` still let you confirm it builds, its non-UI tests
  pass, and it launches without crashing/logging errors — that's the
  ceiling until a macOS-capable interaction tool exists (or the
  Terminal-side Accessibility permission gets revisited).

(Earlier in this project, GUI verification was attempted from a Terminal
session via `screencapture`/`osascript`, and the user withdrew that after a
starker-than-expected macOS screen-recording permission prompt. That's why
the division above exists — not because Terminal sessions technically can't
launch the app, but because driving/inspecting its UI belongs to the Xcode
agent's purpose-built tools instead.)

## Repository state

Three places hold parts of this work; know which before assuming something
is "done":

- **`github.com/stranak/Korpora`, branch `main`** (was `mac-corpora`,
  renamed with the app) — the pushed baseline.
  Holds only the pre-Phase-0 engine: `.gitignore`, `ManateeKit/Package.swift`,
  `ManateeKit/Sources/CManatee/{include/mtcbridge.h,mtcbridge.cc}`,
  `ManateeKit/Sources/ManateeKit/ManateeKit.swift`,
  `ManateeKit/Sources/manateekit-cli/main.swift`,
  `scripts/setup-dev-machine.sh`. Nothing from Phases 0–2 was on the remote
  until this session's commits.
- **`github.com/stranak/manatee-open`, branch `macos-arm64-portability`** —
  a fork of `czcorpus/manatee-open`, the C++ engine. Fully committed and
  pushed, including the `delete_linegroups` heap-corruption fix (see Phase 1
  bugs below). **Not yet opened as a PR to upstream** — the user declined
  that step for now, so it's just sitting on the pushed branch.
- **A SwiftUI shell (`ManateeKit/Sources/ManateeKitApp/`) existed briefly
  as an early proof-of-concept** and was superseded by the AppKit `Corpora`
  app described below (the user's explicit call, citing Daring Fireball's
  SwiftUI-vs-AppKit commentary). It was dropped before ever reaching the
  pushed history, so there's no commit to point to for that decision — this
  paragraph is the record of it.

`manatee-open` itself is **not pinned** by anything in `Korpora` — it's
excluded via `.gitignore` and `scripts/setup-dev-machine.sh` only checks
that a `manatee-open` checkout exists next to this repo, it doesn't clone or
check out a branch. On a fresh machine, clone it explicitly and check out
the right branch *before* running that script:

```
git clone -b macos-arm64-portability https://github.com/stranak/manatee-open.git
```

Otherwise the build silently uses unpatched upstream `manatee-open`,
including the reverted `delete_linegroups` heap corruption.

### Deployment target / minimum toolchain (2026-09-09)

| | Minimum |
| --- | --- |
| macOS to **run the app** | **27.0** — `Korpora/project.yml`, matching this machine's OS, deliberately |
| Xcode to **build the app** | whichever ships the macOS 27 SDK (a deployment target can't exceed the SDK) |
| macOS/Xcode for **`ManateeKit` alone** | 13.0 / Xcode 15+ (`.macOS(.v13)`, `swift-tools-version:5.9`) |
| Xcode to **build the tests too** | **16+** — `KorporaTests` uses Swift Testing (`import Testing`) |
| C++ | `cxx14`, plus a locally built `manatee-open` |

**The app target stays at 27.0 — the user's explicit call (2026-09-09),
after it was briefly lowered to 13.0 and reverted.** The reasoning: this
app is dev-only on a single machine, matching the local OS is what keeps
the ~41 linker warnings silent, and **cross-version portability belongs to
`manatee-open`, not to the app** - which is exactly what its
`macos-arm64-portability` branch is for. `ManateeKit` declares
`.macOS(.v13)` and builds/tests standalone (`swift build`/`swift test`), so
engine work is unaffected by this setting.

Facts worth keeping, all measured rather than assumed:

- **Nothing in the code needs macOS 27.** Forcing
  `MACOSX_DEPLOYMENT_TARGET=13.0` against the current source gives **BUILD
  SUCCEEDED**. `NSTableViewDiffableDataSource` (macOS 11) is the real
  AppKit floor. So 27.0 is a chosen number, not a technical requirement -
  which is what makes the override below safe.
- **Someone on an older Xcode who needs the app** can override per build,
  without touching the repo:
  `xcodebuild ... MACOSX_DEPLOYMENT_TARGET=13.0`
- **What 27.0 buys**, on a clean build: 41 of the otherwise-51 warnings go
  away - the "object file was built for newer macOS version than being
  linked" mismatch. The other 10 are pre-existing (upstream C++ narrowing
  plus Xcode log lines).
- **It only stays silent on a machine whose macOS equals this number.**
  The warnings come from a `manatee-open` static library each developer
  builds locally, so its object files state whichever macOS *that* machine
  runs. There is no value that silences them for everyone.
- **Counting caveat**: linker warnings only appear when linking actually
  happens, so an up-to-date incremental build reports 0 of them and a clean
  build reports all 41. Don't conclude from an incremental build that a
  deployment-target change had no effect.

**Keep `ManateeKit/Package.swift`'s flag arrays as separate statements**
(2026-09-09). The `.unsafeFlags(...)` values used to be built inline as one
expression each — `["-DHAVE_CONFIG_H"] + manateeIncludeDirs.flatMap {
["-I", $0] } + pcre2CFlags` — nested inside the `Package(...)` literal.
Chained `+` over array literals plus a closure gave Swift's type checker
enough overload combinations to blow its budget on *some* toolchains but
not others, so the package built here and failed for someone else with:

```
Package.swift:64:5: error: the compiler is unable to type-check this
expression in reasonable time; try breaking up the expression into
distinct sub-expressions
```

Note the error is reported against `let package = Package(` — line 64,
nowhere near the actual cause, which is what makes it confusing. The flags
are now appended statement by statement with explicit `[String]` types
(verified flag-for-flag identical to the old expression). Anything added
there later should follow the same shape rather than growing a new chained
expression.

## Context

`ManateeKit` wraps `manatee-open` (the C++ corpus-query engine that also
powers KonText, ÚFAL/CNC's open-source corpus concordancer). **Corpora** is
the native macOS app being built on top of it — AppKit rather than SwiftUI,
aiming to cover most of KonText's functionality while adapting the workflow
to native Mac idioms rather than porting the web UI verbatim.

Confirmed product decisions (from earlier in this project):
- **Reference app**: KonText (github.com/czcorpus/kontext) — verified by
  cloning it and reading its actual server-side code, not just docs.
- **Window model**: multi-window/tab, NSDocument-based — each query/
  concordance is its own document.
- **Feature priority**: (1) concordance operations (sort/filter/shuffle/
  sample/line-groups), (2) corpus & subcorpus management, (3) analysis views
  (collocations, frequency distributions). Word sketches are explicitly out
  of scope.
- **Packaging**: dev-only for now (no icon/signing/notarization work).
- **Document persistence model**: dev-only choice, **revisit before real
  release** — `ConcordanceDocument.isDocumentEdited` is hardcoded to
  `false` (2026-09-05) so a concordance is disposable scratch state: running
  sort/filter/shuffle/sample/line-group no longer dirties the document, so
  closing a window or quitting never prompts to Save/Delete/Cancel, and
  unsaved concordances are silently discarded. This was the right call
  *during* active development/testing (constant quit/relaunch cycles were
  getting interrupted by save prompts for throwaway test concordances), but
  it's the opposite of how a finished, "modern macOS app" should feel —
  every open concordance (query + operation chain, not the materialized
  rows — see `DocumentState`) should transparently survive quit/relaunch
  with no explicit Save, the same way Notes/TextEdit/Safari resume exactly
  where you left off. Making that the real pre-release behavior needs:
  1. Removing/reverting the `isDocumentEdited` override above (or gating it
     behind a debug-only flag) so documents can autosave-and-resume instead
     of always discarding.
  2. Restoring `window.isRestorable = true` /
     `NSQuitAlwaysKeepsWindows = true` (`Corpora/Corpora/Controllers/
     ConcordanceWindowController.swift`, `Corpora/Corpora/Info.plist`) —
     currently forced off because they caused a stuck-restoration-state bug
     that silently swallowed a launch (no window, no error) after repeated
     force-kills during dev testing (see Phase 0's bugs list). That
     workaround needs a real root-cause fix instead of leaving restoration
     disabled, or the "silent resume" this item wants can't come back
     safely.
  3. Reconsidering `AppDelegate.applicationShouldTerminate` (added
     2026-09-05, always returns `.terminateNow`) — added as an explicit,
     unconditional guarantee that the app can always quit instantly with no
     alert, from a script or the system as well as the user, independent of
     any document's edited state. A real persistence model doesn't
     necessarily conflict with this (autosave-and-resume can still happen
     on an unconditional-terminate path), but it needs to be re-examined
     alongside items 1–2, not left as an accidental leftover from the
     disposable-scratch model.
- **Tests**: ManateeKit's tests are XCTest, not this workspace's usual Swift
  Testing convention — a known divergence, not something to rewrite
  speculatively.

## Status summary

| Phase | Engine (ManateeKit/CManatee) | AppKit UI | Visually verified |
|---|---|---|---|
| 0 — AppKit shell, NSDocument, query parity | done | done | yes (screenshots, earlier session) |
| 1 — sort/filter/shuffle/sample/line-groups | done, 17 tests passing (cumulative) | done, plus header-click-sort + merged Operations/Clear-Groups popover with one row per active group (2026-09-05) | **yes — sort, sample, filter, shuffle, multi-row selection, multi-row line-group assignment, per-group Operations popover (incl. live-refresh fix), and row context menu (filter-to-selection/copy) all confirmed by user; see verification log for the full trail of bugs found & fixed along the way** |
| Settings (Cmd-,) | n/a | done | yes (screenshots, earlier session) |
| 2 — corpus info + subcorpus management | done, 17/17 tests passing | done, builds & launches cleanly | **yes — Settings, Sort, subcorpus creation/query, and quit/close-anytime behavior all confirmed by user; see verification log** |
| 3 — collocations, frequency distributions | done, 25/25 ManateeKit tests passing | done, builds cleanly, 8/8 CorporaTests passing | **yes — both toolbar buttons, sheets, sorting, and disposability all confirmed by user; see verification log** |
| 4 — corpus import & memory residency | done, 32/32 ManateeKit tests passing | done, builds cleanly, 8/8 CorporaTests passing | **not yet — needs manual click-through, see Phase 4 writeup** |
| 5 — concordance UX (context/history/KWIC attrs/doc info/export) | done, 42/42 ManateeKit tests passing | done, builds cleanly, 32/32 CorporaTests passing | **partial — 5.1-5.4 confirmed by user (see Phase 5 writeup, incl. an accepted non-blocking hover-tooltip bug); 5.5 not yet manually click-tested** |
| 6 — concordance UX round 2 (KonText comparison, 11 items) | 6.1-6.8 done, 59/59 ManateeKit tests passing; 6.9-6.11 not started | 6.1-6.8 done, builds cleanly, 79/79 KorporaTests passing; 6.9-6.11 not started | partial — 6.1-6.6a all confirmed working by user; 6.7 is engine-only (tests, nothing to click); **6.8 rescoped by the user and rebuilt, not yet click-tested**; 6.9-6.11 not started |

All Swift/C++ code builds cleanly and all ManateeKit tests pass (`swift
test` → 17/17).

## Phase 0 — AppKit shell, NSDocument model, query parity (done)

- `Korpora/Korpora.xcodeproj`, generated via `xcodegen` from
  `Korpora/project.yml`, sibling to `ManateeKit/`. Depends on `ManateeKit`
  as a local Swift package. Regenerate with `cd Korpora && xcodegen
  generate` after adding/removing source files (Xcode won't pick them up on
  its own).
- `main.swift`: manual bootstrap (no storyboard). Calls
  `AppSettings.shared.applyEnvironment()` and instantiates
  `CorporaDocumentController` before `NSApplication.run()` — both must
  happen before AppKit's automatic untitled-document-at-launch path fires,
  which happens *very* early (before `applicationDidFinishLaunching`,
  discovered the hard way).
- `AppDelegate.swift`: programmatic main menu (App/File/Edit/Window + a
  Settings… item, Cmd-,). Implements
  `applicationSupportsSecureRestorableState` and disables window
  restoration (see bugs below).
- `Documents/ConcordanceDocument.swift`: the `NSDocument` subclass. Holds
  `corpusName`, `subcorpusPath: String?`, `initialQuery`,
  `leftContext`/`rightContext`/`kwicAttr`, `operations:
  [ConcordanceOperation]`, `rows: [ConcordanceRow]`, `status`. Persists via
  a `Codable` `DocumentState` JSON blob (query + operation chain only,
  never the materialized rows). `makeWindowControllers()` either replays an
  already-parameterized document or presents `NewConcordanceSheetController`
  for a blank one.
- `Controllers/CorporaDocumentController.swift`: an `NSDocumentController`
  subclass, currently just a marker (installed early so it becomes
  `NSDocumentController.shared`). The "ask for corpus + query" flow actually
  lives in `ConcordanceDocument.makeWindowControllers`, not here — see the
  bug note below for why.
- `Controllers/ConcordanceWindowController.swift` /
  `ConcordanceViewController.swift`: one window per document, native
  tabbing. Toolbar (Sort/Filter/Shuffle/Sample/Operations, custom
  `NSButton`-backed items — Operations replaced a separate Clear Groups
  button, see Phase 1's writeup below). Query bar (`CQLQueryField`) + status
  label +
  `NSTableView` (Group/Left/Match/Right columns via
  `NSTableViewDiffableDataSource`). Row context menu: assign line group,
  filter to selection, copy.
- `Controllers/FilterSheetController.swift`: the sheet behind the toolbar's
  Filter button — a positive/negative sub-query over a token window around
  each hit, matching KonText's own filter form (including its -5/5 default
  window; builds a `PNFilterSpec`).
- `Controllers/SortPopoverController.swift`: the toolbar's Sort popover —
  a single sort level (multi-level sort is already in the model via
  `SortCriteria`, but isn't worth a UI for until someone needs it).
- `Controllers/SamplePopoverController.swift`: the toolbar's Sample
  popover — an absolute line count, matching KonText's own sample form (no
  percentage option; see `LiveConcordance.sample`'s doc comment).
- `Views/CQLQueryField.swift`: auto-growing `NSTextView`-backed query
  editor, basic CQL syntax coloring + keyword completion.
- `Views/KWICCellView.swift`: styled table cells + the Group badge; font
  comes from `AppSettings.resultsFont`.
- `Controllers/NewConcordanceSheetController.swift`: corpus picker (from
  `ManateeKit.CorpusRegistry.availableCorpusNames()`), also shows corpus
  info and a subcorpus picker (Phase 2 — see below).
- `Settings/`: `AppSettings` (UserDefaults-backed:
  `corpusRegistryDirectories`, `resultsFontName`/`Size`),
  `SettingsWindowController` (classic multi-pane `.preference`-style
  toolbar), `GeneralSettingsViewController` (directory list),
  `AppearanceSettingsViewController` (Font Panel picker).
- `Korpora/Korpora/Korpora.entitlements`: sandboxing explicitly disabled
  (`com.apple.security.app-sandbox` = false) — needed for arbitrary
  registry/corpus-directory access during dev; revisit before any real
  distribution.

**Real bugs found and fixed along the way:**
- AppKit's automatic "open untitled document at launch" calls
  `openUntitledDocumentAndDisplay(false)` and shows the window through a
  *separate* internal path — code gated on `displayDocument == true` there
  never runs at launch. Fixed by moving the "present the new-concordance
  sheet" logic into `ConcordanceDocument.makeWindowControllers()` instead of
  the document-controller override.
- macOS window-state restoration could silently swallow a launch (no
  window, no error) after repeated force-kills during dev testing. Fixed
  with `applicationSupportsSecureRestorableState() -> true`,
  `window.isRestorable = false`, `NSQuitAlwaysKeepsWindows = false` in
  Info.plist. For manual dev launches, pass `-ApplePersistenceIgnoreState
  YES` as a process argument to bypass any stuck restoration state.
- `NSTableViewDiffableDataSource` left stale cells on screen when only a
  row's *content* changed (e.g. a line-group assignment) without its `id`
  changing — diffable data sources only re-render on identity/order
  changes. Fixed by calling `snapshot.reloadItems(_:)` for the current ids
  on every refresh.

## Phase 1 — Concordance operations (done)

- `ManateeKit/Sources/CManatee/include/mtcbridge.h` /
  `ManateeKit/Sources/CManatee/mtcbridge.cc`: `mtc_kwic_open` now uses
  `RS(true)` (reflects the concordance's current *view*, i.e. sort/shuffle
  order — it used to always render raw order). New:
  `mtc_concordance_sort(conc, criteria, uniq, error)`,
  `mtc_concordance_shuffle`, `mtc_concordance_reduce(size)` (sample),
  `mtc_concordance_set_collocation` + `mtc_concordance_pnfilter` (filter),
  `mtc_concordance_set_linegroup`/`get_linegroup`/`delete_linegroups`.
- `ManateeKit/Sources/ManateeKit/LiveConcordance.swift`: a new actor
  keeping one live `Concordance` handle open across operations (the actual
  Phase 1 gap — `Corpus.query(_:)` used to open-then-discard a handle per
  call). `sort(_:unique:)`, `shuffle()`, `sample(lines:)`, `filter(_:)`,
  `setLineGroup(rangeStart:rangeLen:group:)`, `linegroup(at:)`,
  `deleteLineGroups(_:invert:)`, `kwicLines(...)`. Plus
  `SortCriteria`/`SortLevel`/`SortAnchor` and `PNFilterSpec`/`MatchRank`
  (all `Codable` + `Sendable`).
- `Corpora/Corpora/Documents/ConcordanceOperation.swift`: the `Codable`
  enum (`.sort`, `.filter`, `.shuffle`, `.sample`, `.setLineGroup`) that's
  actually persisted and undone — `ConcordanceDocument.setOperations`
  registers `NSUndoManager` actions and replays the whole chain from
  scratch against a fresh `LiveConcordance` (Manatee can't remove a middle
  operation, only replay).
- Toolbar mutual exclusion: once any line-group exists, Sort/Filter/
  Shuffle/Sample disable (mirrors KonText's own rule) — verified visually
  earlier. (Originally a separate "Clear Groups" button also enabled at
  this point; since the 2026-09-05 merge into the Operations popover, that
  button no longer exists — Operations stays enabled unconditionally, see
  below.)
- **Column-header click-to-sort (added 2026-09-05):** clicking the Left/
  Match/Right column header sorts by `word` at that anchor (span 1);
  clicking the same header again toggles ascending/descending, matching
  standard macOS table behavior (`NSTableColumn.sortDescriptorPrototype` +
  `Corpora/Corpora/Views/SortableTableView.swift`, a tiny `NSTableView`
  subclass that observes `sortDescriptors` changes directly, since
  `NSTableViewDiffableDataSource` — our data source — doesn't forward the
  optional `sortDescriptorsDidChange` data-source callback). Each click is a
  real, undoable `ConcordanceOperation.sort` (Cmd-Z undoes it), consistent
  with the toolbar's Sort popover. Manatee itself has no native descending
  sort (`LiveConcordance.sort` is always ascending — see the "Reverse"
  finding below), so `ConcordanceOperation.sort` gained a `descending` flag
  that's never sent to Manatee; `ConcordanceDocument.replay()` just reverses
  the already-ascending-sorted display rows as its last step when set. The
  header indicator triangles are synced from whatever sort is actually
  active in `document.operations` (`syncSortIndicators()` in
  `ConcordanceViewController`), regardless of whether it came from a header
  click, the toolbar popover, or undo/redo — a sort that isn't a
  single-level `word` sort on one of these three columns just clears every
  indicator, since it doesn't correspond to a header. A third click does
  *not* clear the sort back to raw order — this mirrors AppKit's own native
  two-state (ascending/descending) click behavior rather than older Mac
  apps' three-state cycle, which doesn't appear to be a documented/current
  HIG convention.
- **Operations popover (added 2026-09-05):** a new toolbar button
  ("Operations", `xmark.circle`) lists every active sort/filter/shuffle/
  sample with a per-row remove button (`OperationsPopoverController`) —
  requested after manual testing found that Undo alone (which can only
  unwind the *most recent* operation) wasn't flexible enough to drop one
  specific sort or filter out of the middle of a chain. `ConcordanceOperation`
  gained a `summary` computed property (human-readable label) and
  `ConcordanceDocument` gained `removeOperation(at:)`, which reuses the same
  `setOperations` path every other mutation goes through — so removing one
  operation this way is itself undoable via Cmd-Z, consistent with
  everything else. This button stays enabled even when line groups are
  active (unlike Sort/Filter/Shuffle/Sample), since reviewing/removing
  *existing* operations doesn't conflict with an active line-group view the
  way starting a *new* one would.
- **Merged into "Clear Groups" (2026-09-05):** the separate "Clear Groups"
  toolbar button was folded into the Operations popover after user
  feedback that having two separate "cancel things" affordances was
  confusing — the button's icon (`xmark.circle`, "cancel/clear") was
  clearer than the list-style "Operations" icon it replaced, but the
  popover-with-a-list *mechanism* was the better interaction, so line
  groups now show as one aggregate row ("Line groups (N lines tagged)",
  since there can be many individual line-group operations) inside the
  same popover, with its own remove button calling the existing
  `performClearLineGroups()`. There is now exactly one toolbar item for
  reviewing/canceling active state, not two.
- **Real bug found and fixed (2026-09-05):** the concordance table couldn't
  select more than one row — Cmd-click and Shift-click both behaved like a
  plain click. Root cause: `NSTableView.allowsMultipleSelection` defaults
  to `false`, and since this table is built entirely programmatically (no
  Interface Builder, where the default checkbox is checked), nothing ever
  turned it on. One-line fix in `ConcordanceViewController.setUpTableView()`.
  This is also what the row context menu's `assignLineGroup`/`targetedRows()`
  multi-row path was written to support but couldn't actually reach before.
- Tests in `ManateeKitTests.swift` + `LiveConcordanceTests.swift` +
  `Corpora/CorporaTests/ConcordanceOperationTests.swift` (the `descending`
  flag, `singleLevelSort` extraction, `summary` text, and `removeOperation`
  bookkeeping — the latter exercised via a bare `ConcordanceDocument()` with
  no corpus, since `replay()` no-ops without one, so no MANATEE_REGISTRY is
  needed for this class of test).

**Real bugs found and fixed along the way:**
- A genuine upstream bug in `manatee-open`: `concord/concgrp.cc`'s
  `delete_linegroups` freed a `malloc`'d buffer with C++ `delete` (heap
  corruption, manifesting as a crash in an unrelated *later* call). Fixed
  and committed to `stranak/manatee-open`, branch `macos-arm64-portability`,
  pushed to origin (see Repository state above).
- A use-after-free in `LiveConcordance` itself: it stored a corpus's raw
  pointer without keeping the parent `Corpus` actor alive, so ARC could
  free it out from under a still-live concordance.
- An inverted `includeKwic`/`exclude_kwic` polarity bug in
  `LiveConcordance.filter`.

## Phase 2 — Corpus & subcorpus management (engine done + tested; AppKit UI implemented)

### Engine (ManateeKit/CManatee) — done, 17/17 tests passing

- Shim additions: `mtc_corpus_attr_count`/`attr_name`,
  `mtc_corpus_struct_count`/`struct_name`,
  `mtc_corpus_struct_attr_count`/`struct_attr_name` — read the
  already-parsed `Corpus::conf` (`CorpInfo`) tree, no engine work needed.
  `mtc_create_subcorpus(corp, subcPath, structName, query, error)`,
  `mtc_subcorpus_open(parent, subcPath, error)` — the latter returns a
  plain `MTCCorpus`, since `SubCorpus` *is a* `Corpus` in C++, so every
  existing call (`mtc_query`, sort/filter/etc.) works on it unchanged.
- `Corpus.name` (new stored property), `Corpus.info() -> CorpusInfo`
  (`attributes: [String]`, `structures: [StructureInfo]`),
  `Corpus.createSubcorpus(named:structure:query:) -> String` (path),
  `Corpus.openSubcorpus(atPath:) -> Corpus`.
- `ManateeKit/Sources/ManateeKit/SubcorpusStore.swift`: where subcorpus
  `.subc` files live (`~/Library/Application
  Support/Corpora/Subcorpora/<corpusName>/<subcorpusName>.subc`) and how to
  list them.
- **Important discovered semantic** (cost a debugging cycle): `create_subcorpus`'s
  `query` parameter is evaluated with the *structure itself* as the corpus,
  so structural attributes are unprefixed and **CQL brackets are not
  used**. E.g. to restrict to `<doc id="1">`, the query is `id="1"` — not
  `[id="1"]`, not `[doc.id="1"]`.
- Also fixed: `mtc_corpus_size` used `Corpus::size()`, which always reports
  the *parent* corpus's full token count — only `search_size()` is
  overridden by `SubCorpus`. Switched to `search_size()` (a harmless no-op
  for regular corpora, correct for subcorpora).
- Tests: `CorpusInfoTests.swift`, `SubcorpusTests.swift`.

### AppKit UI — implemented

- `NewConcordanceSheetController` was extended: selecting a corpus now
  fetches and shows its `CorpusInfo` (attributes + structures) in an info
  label, and a new Subcorpus popup lists
  `SubcorpusStore.availableSubcorpora(for:)` plus "Whole Corpus" and "New
  Subcorpus…". `onCommit` signature is now `(corpusName, subcorpusPath:
  String?, query)`.
- `Corpora/Corpora/Controllers/NewSubcorpusPopoverController.swift`: name
  field, structure popup (from `CorpusInfo.structures`), a CQL restriction
  field, Create button — calls `Corpus.createSubcorpus`.
- `ConcordanceDocument` gained `subcorpusPath: String?` (persisted).
  `replay()` now opens the subcorpus via `Corpus.openSubcorpus(atPath:)`
  when set and queries against *that*. The status line reads "N hits in an
  M-token subcorpus "name"" vs. "...corpus" accordingly.
- `Corpora/scripts/build-dev-corpus.sh` builds a 5-document dev corpus
  (updated 2026-09-05 — was 2 documents, matching `id="1"`/`id="2"` only).
  Deliberately **not** the same as `TestCorpusFixture` anymore: the ManateeKit
  test fixture stays a minimal 2-`<doc>` corpus for fast, deterministic
  automated tests, while the dev corpus needs enough real variety that
  creating a subcorpus demonstrates an actual *subset* of documents, not
  just "restrict to the one specific id you picked." Each `<doc>` now has
  `id`/`author`/`genre`/`year` attributes:

  | id | author | genre | year |
  |---|---|---|---|
  | 1 | twain | fiction | 1876 |
  | 2 | twain | fiction | 1884 |
  | 3 | austen | fiction | 1813 |
  | 4 | reuters | news | 2020 |
  | 5 | reuters | news | 2021 |

  So e.g. `author="twain"` (structure `doc`) restricts to docs 1+2 (2 of 5),
  `genre="fiction"` to docs 1+2+3 (3 of 5), `genre="news"` to docs 4+5.
  **Subcorpus creation itself is confirmed working** — the user tested
  `year="2021"` (doc 5 only) and got the expected 8-line/30-token result
  with 2 `[tag="JJ"][tag="NN"]` hits.
  - Each doc still has one `[JJ][NN]` sentence (10 total: brown fox, lazy
    dog, curious cat, sleepy cat, elegant lady, proud gentleman, local
    market, global economy, annual report, modest profit — doc 1's first
    sentence keeps an extra leading JJ, "quick", testing that `[JJ][NN]`
    doesn't match a JJ-JJ pair), but **every sentence is now padded with
    >=5 tokens of repeated filler on each side of the match** (15 tokens
    per sentence, 16 for doc 1's illustrative one; 151 tokens total; each
    doc is ~30 tokens, except doc 1 at 31). This was a deliberate fix, not
    the original design — see the next bullet.

**Real bug found and fixed (2026-09-05, dev corpus only, not app code):**
filtering a concordance for `[word="fox"]` was also keeping the "lazy dog"
line. Traced precisely: the two words were only 4 raw token positions
apart in the *original* 2-document corpus's back-to-back 4-5-token
sentences, well inside the Filter feature's default ±5-token search
window (`FilterSheetController`'s `leftOffset`/`rightOffset` defaults,
matching KonText's own convention). Confirmed via
`manatee-open/concord/concctx.cc`'s `prepare_context`: the window is a
literal ±5 raw-position range around the match, with no sentence-boundary
awareness for a plain numeric offset. **Not a defect in
`LiveConcordance.filter`/`mtc_concordance_set_collocation`/Manatee's
`Concordance::set_collocation`** — verified by hand with
`manateekit-cli testcorp '[word="fox"]'` / `'[word="dog"]'`, showing they sat
in each other's context window even at the KWIC display's own wider ±10.
Fixed by padding every sentence so unrelated content words are always
>5 tokens apart (see above) — re-verified the same way, "fox"'s ±10
context no longer contains "dog" at all, and the `[JJ][NN]` query still
returns exactly the original 10 matches, same order, same content.

### Verification log

**2026-09-05, Xcode agent session:**

- `xcodegen generate` re-run after adding a smoke test
  (`Corpora/CorporaTests/ConcordanceOperationTests.swift`, a
  `ConcordanceOperation` Codable round-trip + `isLineGroupOperation` check —
  the directory was previously empty despite `project.yml` wiring it up as
  a test target source).
- `BuildProject` (buildForTesting) → **succeeded** on the `Corpora` scheme.
- `RunAllTests` → **2/2 passed** (`CorporaTests`, i.e. the new smoke test —
  this is everything the scheme's test plan currently covers; it does not
  include ManateeKit's suite).
- `cd ManateeKit && swift test` → **17/17 passed**.
- `RunProject` → app launched successfully (PID captured); `GetConsoleOutput`
  showed only benign macOS system noise (Intents-framework registration,
  ViewBridge disconnects) — no crash, no app-level error output.
- **Not confirmed — tooling gap, see the Division of labor correction
  above:** the actual click-through items below (New Concordance sheet
  contents, subcorpus creation/selection/query restriction, status line
  phrasing, Phase 1 toolbar/undo/Settings interaction). `DeviceInteraction*`
  rejected the macOS target outright, and no other available tool can
  synthesize clicks/typing into an AppKit window. These remain open:

1. Open `Korpora/Korpora.xcodeproj`. If `DevCorpus/` doesn't exist — or the
   app aborts on launch because its registry's baked-in absolute `PATH` no
   longer resolves — run `Korpora/scripts/build-dev-corpus.sh` (idempotent).
   The Xcode
   scheme's `MANATEE_REGISTRY` already points at it (see `project.yml`).
2. Build + run. The New Concordance sheet should show corpus `testcorp`,
   with an info label listing its attributes (word/lemma/tag) and
   structures (doc (id, author, genre, year), s), and a Subcorpus popup
   defaulting to "Whole Corpus".
3. ~~Try "New Subcorpus…"~~ — **done**, confirmed 2026-09-05 with
   `year="2021"` (doc 5 only, 8 lines/30 tokens, 2 `[tag="JJ"][tag="NN"]`
   hits). Other useful restrictions if revisiting (structure is always
   `doc`, no brackets/prefix): `author="twain"` → docs 1+2 (61 tokens),
   `genre="fiction"` → docs 1+2+3 (91 tokens), `genre="news"` → docs 4+5
   (60 tokens).
4. Spot-check Phase 1's toolbar (Sort/Filter/Shuffle/Sample/Operations),
   the row context menu, undo/redo, and Settings (Cmd-,) with real
   interaction (clicking, typing).
5. Record results in this file's status table and this section; file any
   defects found as new work above rather than silently fixing and
   forgetting.

Whoever next has a way to actually drive the AppKit UI (a human, a
Terminal session with Accessibility permission re-granted, or a future
tool) should run items 1–4 and update this log and the status table.

**2026-09-05, user manual click-through (items 1, 4):**

- Subcorpus flow (item 3) not yet reported on.
- **Real bug found and fixed:** Settings… was greyed out in the menu and
  Cmd-, did nothing. Root cause: `AppDelegate.makeMainMenu()` was a `static
  func`, so `self` inside it was the `AppDelegate` *type*, not the running
  instance — `settingsItem.target = self` pointed the menu item at the
  class object, which doesn't implement the instance method
  `showSettings(_:)`, so AppKit's automatic menu validation disabled it.
  Fixed by making `makeMainMenu` an instance method.
- **Reported as broken, turned out not to be:** "sorting seemed not to
  work." Traced end-to-end (toolbar button → popover → `ConcordanceDocument.
  performSort` → `LiveConcordance.sort`) and found no defect — confirmed by
  reproducing the user's exact report with the default Sort settings
  (attribute `word`, anchor `Match`, ascending) against the dev corpus's
  `[tag="JJ"][tag="NN"]` query: raw order is `brown fox, lazy dog, curious
  cat, sleepy cat`; sorted order is `brown fox, curious cat, lazy dog,
  sleepy cat` — only the middle two rows swap, easy to miss on a 4-line
  result set. `LiveConcordanceTests.testSortOrdersByKwicAttribute` already
  covers exactly this case.
- **Real (pre-existing) UX bug found while chasing the above:** the Sort
  popover's "Reverse" checkbox does not toggle ascending/descending order —
  there is no such toggle anywhere in this UI; every sort is ascending on
  the chosen key. "Reverse" is Manatee's own `r` ("retrograde") sort flag:
  it compares each word's *spelling reversed* (e.g. sorting by word ending/
  suffix), confirmed by reading `manatee-open/concord/conccrit.cc`'s
  `strip_options`/`str2retro` and reproducing the user's observed
  `brown fox, curious cat, sleepy cat, lazy dog` result by hand from the
  reversed-spelling comparison. This matches KonText's own sort form
  faithfully but reads as a direction flip to anyone unfamiliar with that
  convention. Decision: keep the feature exactly as-is (matches the
  reference app), just relabel it — the checkbox now reads "Reverse (by
  word ending)", and `SortLevel.reverse` in ManateeKit gained a doc comment
  explaining the same thing.

**2026-09-05, user manual click-through, continued:** Settings confirmed
fixed (font change in Appearance settings applied correctly). Sort
confirmed working both via the toolbar's Sort popover and via clicking the
Left/Match/Right column headers directly. Indicator-triangle/undo edge
cases (switching between header-click and popover sorts, undo/redo) weren't
specifically called out but no issues were reported. Sample and Filter also
confirmed working. Feedback from this round: Undo alone wasn't flexible
enough to remove one specific sort/filter/sample without unwinding
everything after it — addressed by the new Operations popover (see Phase
1's writeup above), **not yet manually verified**. Also: the dev corpus's 2
documents weren't enough to demonstrate a real subcorpus subset — addressed
by expanding it to 5 documents with `author`/`genre`/`year` attributes (see
Phase 2's writeup above), also **not yet manually verified**.

**2026-09-05, user manual click-through, continued again:** Operations
popover confirmed working. Subcorpus flow confirmed working (`year="2021"`
→ doc 5 only, 8 lines/30 tokens, 2 hits). New finding: filtering
`[word="fox"]` was also keeping the "lazy dog" line — a dev-corpus sizing
bug (short, back-to-back sentences put unrelated words within the Filter
feature's default ±5-token window), not an app defect; fixed by padding
every sentence with filler so unrelated content words are always >5 tokens
apart (see Phase 2's writeup above for the full trace). Also renamed the
dev corpus from `Corpora/.devcorpus/` to `Corpora/DevCorpus/` — the
project's convention is everything visible except `.git` and tool-managed
build directories (`.build`, `.swiftpm`). Still outstanding: the row
context menu (assign line group, filter-to-selection, copy) and undo/redo
across the newer additions (header-click-sort, Operations popover).

**2026-09-05, row context menu tested, two more findings:** everything
worked except multi-row selection. **Real bug found and fixed:** Cmd-click/
Shift-click couldn't select more than one row at all — `NSTableView.
allowsMultipleSelection` defaults to `false` and nothing had turned it on
for this programmatically-built table (see Phase 1's writeup above).
**UX feedback addressed:** having both a standalone "Clear Groups" button
and a separate "Operations" popover felt like two overlapping ways to
cancel things — merged into one Operations button (keeping the clearer
"cancel" icon, `xmark.circle`) whose popover now also lists line groups as
one aggregate, removable row. **Not yet re-verified**: multi-row line-group
assignment (`assignLineGroup`'s `targetedRows()` path, which needed
multi-selection to ever be reachable) and the merged Operations/Clear
Groups popover.

**2026-09-05, multi-row selection re-verification, app crash found and fixed
(Terminal session):** user confirmed Cmd-click/Shift-click multi-selection
itself now works, but the app crashed when assigning several selected lines
to a line group at once. Root cause: `ConcordanceDocument.replay()` opens a
brand-new `Corpus`/`LiveConcordance` (a fresh Manatee handle) on every call,
and `ConcordanceViewController.assignLineGroup` called
`performSetLineGroup` once per selected row in a synchronous loop — each
call independently ran `appendOperation` → `setOperations` → `replay()`,
firing one unawaited `Task` per row. Manatee's thread-safety is only
documented/assumed safe *within* one actor instance (see `LiveConcordance`'s
doc comment); nothing serializes access *across* separate instances, so a
multi-row assignment opened several concurrent handles and queries against
the engine at once and crashed it. Fixed two ways:
1. `ConcordanceDocument` gained `performSetLineGroups(_:group:)`, which
   appends all the selected rows' `.setLineGroup` operations in one
   `setOperations` call (one replay, one undo step) —
   `assignLineGroup` now calls this instead of looping.
2. `replay()` itself now serializes: a stored `currentReplayTask` is
   awaited by the next `replay()` call before it touches the engine, so
   even an unrelated pair of rapid actions (not just this one) can no
   longer run concurrently.

Verified: `xcodebuild -project Corpora.xcodeproj -scheme Corpora build` →
**BUILD SUCCEEDED**.

**2026-09-05, re-verified (user):** multi-row selection and multi-row
line-group assignment both confirmed working — the crash is fixed.

**2026-09-05, quit/close-anytime confirmed (user):** with
`ConcordanceDocument.isDocumentEdited` hardcoded false and
`AppDelegate.applicationShouldTerminate` returning `.terminateNow`
unconditionally (both above), closing windows and quitting no longer
prompts under any circumstance tested — matches the "disposable scratch
state" decision recorded above. Remember this is explicitly a dev-time
tradeoff to revisit before release (see the "Document persistence model"
bullet).

Also noteworthy from this session: the user was surprised the app reopened
last session's concordance on launch. Traced to
`ConcordanceDocument.override class var autosavesInPlace: Bool { true }` —
NSDocument's own autosave/resume mechanism, which silently reopens
previously-open autosaved documents on next launch. This is a *different*
mechanism from the window-restoration bits already disabled elsewhere
(`window.isRestorable = false`, `NSQuitAlwaysKeepsWindows = false`,
`applicationSupportsSecureRestorableState`) — those don't affect it. Not
changed; recorded here since it's easy to mistake for stuck window-
restoration state (a previously-fixed bug, see Phase 0) rather than this
separate, working-as-designed autosave path.

**2026-09-05, Operations popover per-group listing confirmed working, then
refined (user + Terminal session):** the merged Operations/Clear Groups
popover itself confirmed working as-is. Follow-up UX request: list each
line group separately instead of one aggregate "Line group(s) (N lines
tagged)" row, so a single group can be cleared without wiping every group
at once. Implemented:
- `ConcordanceDocument.performClearLineGroups()` (cleared every line-group
  operation) replaced with `performClearLineGroup(_ group:)`, which only
  drops `.setLineGroup` operations for that specific group number and
  replays — safe to filter by group number alone (ignoring position)
  because sort/filter/shuffle/sample stay disabled the entire time any line
  group exists, so every `.setLineGroup` operation in the chain runs
  against the same, unchanging view order.
- `OperationsPopoverController.lineGroupCount: Int` replaced with
  `lineGroups: [(group: Int, lineCount: Int)]`, one removable row per
  active group (group 0/"None" excluded — nothing meaningful to clear about
  it), each row's remove button now calls `onClearLineGroup(group)`.
- `ConcordanceViewController.updateOperationsPopover` now derives the
  per-group counts from `document.rows`' actual current `group` field
  (grouped/counted directly), not from raw operation counts — so a line
  reassigned from one group to another is only ever counted under its
  current group, not double-counted under a stale one.

Verified: `xcodebuild -scheme Corpora build` → **BUILD SUCCEEDED**.

**2026-09-05, re-verified, one lag bug found and fixed (user + Terminal
session):** removing a group correctly updated the concordance table
immediately, but the popover's own row for that group only disappeared
after clicking a second time (on that row or any other). Root cause:
`performClearLineGroup`'s `replay()` is async and only updates
`document.rows` once the engine query actually finishes, but
`ConcordanceViewController.operationsTapped`'s `onClearLineGroup`/`onRemove`
handlers called `updateOperationsPopover` *synchronously*, immediately
after kicking off that replay — always reading the pre-replay, stale
`document.rows`. The main table didn't have this problem because
`document.onResultsChanged` was already wired to `refresh()`, which runs
*after* the replay completes; the popover just wasn't hooked into that same
signal, so it only ever caught up on whatever *next* button click happened
to call `updateOperationsPopover` again. Fixed by tracking the open popover
(`ConcordanceViewController.activeOperationsPopover`, weak) and having
`refresh()` itself call `updateOperationsPopover` on it when present, so it
updates at the same time as the table rather than only at the next click.
Verified: `xcodebuild -scheme Corpora build` → **BUILD SUCCEEDED**. Not yet
manually re-verified by the user.

**2026-09-05, build-warning cleanup (Terminal session):** user asked about
~41 build warnings and whether they're worth fixing. Broke down into four
buckets:
1. **Fixed** — 3x "no 'async' operations occur within 'await' expression":
   `try await Corpus(name:)` in `ConcordanceDocument.replay()` and
   `NewConcordanceSheetController` (two call sites) — `Corpus.init(name:)`
   is `throws`, not `async throws`, so the `await` was always a no-op.
   Dropped it (kept `try`).
2. **Fixed** — 2x "non-Sendable type 'OpaquePointer' ... cannot exit
   actor-isolated context; this is an error in the Swift 6 language mode":
   `LiveConcordance.init` reading `corpus.handle` (a different actor's
   property) across isolation. `Corpus.handle`
   (`ManateeKit/Sources/ManateeKit/ManateeKit.swift`) is now
   `nonisolated(unsafe) let handle: OpaquePointer` — sound because it's
   immutable and only ever a raw pointer *value*; the actors' whole job is
   serializing the engine *calls* that use it, not gatekeeping the pointer
   value itself, so this doesn't weaken the safety `Corpus`/`LiveConcordance`
   being actors was for. This one was a real forward-compat issue (would
   become a hard error under Swift 6 mode), worth fixing now rather than
   later. `LiveConcordance.init` updated to read it without `await`
   accordingly (`ManateeKit/Sources/ManateeKit/LiveConcordance.swift`).
3. **Left alone, not worth it (dev-only project)** — ~38 linker warnings,
   "object file ... was built for newer macOS version (26.0/27.0) than
   being linked (13.0)", from `manatee-open`'s prebuilt
   `libbuiltinmanatee.a` plus one for the Homebrew `libpcre2` dylib. Purely
   a deployment-target mismatch between how `manatee-open` was built
   locally and Corpora's Debug deployment target; harmless on the
   development machine (always current macOS). Would need a `manatee-open`
   build-config change (its own `configure`/Makefile invocation, not
   anything in this repo) — worth revisiting only alongside real packaging/
   distribution work, not now.
4. **Left alone, upstream code** — 5x `-Wshorten-64-to-32` (implicit
   64→32-bit integer narrowing) in `manatee-open` headers (`finlib/
   regexplex.hh`, `finlib/generator.hh`, `concord/concord.hh` x2, `concord/
   concget.hh`). Pre-existing upstream C++ code, not something this fork
   has touched; no evidence of an actual bug behind any of them (line/token
   counts fitting in `int` in practice for corpora this size). Not worth
   chasing without a concrete symptom.

Verified: rebuilt after 1–2 with `xcodebuild -scheme Corpora clean build`
→ zero warnings left besides buckets 3–4; `cd ManateeKit && swift test` →
17/17 still passing.

## Phase 3 — Collocations & frequency distributions (engine + AppKit UI done)

Full plan (research, decisions, exact signatures) is preserved at
`/Users/stranak/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/plans/ethereal-scribbling-yeti.md`
from the planning session — this section is the as-built summary.

**Confirmed with the user before building:** both features ship together
(they share almost all the plumbing); results are plain auxiliary windows,
**not** `NSDocument`s — a disposable, re-runnable report view fed by the
current concordance's live handle, not a persisted/undoable artifact. This
matches the concordance document's own current disposable-by-default
behavior (see "Document persistence model" above) rather than fighting it.

### Engine (ManateeKit/CManatee)

- **Collocations** wrap `concord/concstat.hh`'s `CollocItems` — per-word
  freq/co-occurrence-count plus any `corp/bgrstat.cc` association measure
  computed on demand. New shim: `mtc_colloc_open`/`_next`/`_get_item`/
  `_get_freq`/`_get_cnt`/`_get_bgr`/`_close`
  (`ManateeKit/Sources/CManatee/`). `CollocItems` starts already positioned
  at its best-scoring item (unlike `KWICLines`, which starts before its
  first line) — `mtc_colloc_next` tracks a `started` flag internally so it
  can still offer the same `while (mtc_colloc_next(items))` calling
  convention as `mtc_kwic_next`.
- **Frequency distributions** wrap `Corpus::freq_dist`'s struct-out overload
  (`corp/corpus.hh`). `count_structattr_vals`, named in the original
  sketch, turned out to be **SWIG-only Python sugar with no real C++
  declaration** (only referenced in `manatee-open/api/manatee.i`'s `%extend
  Corpus` block) — `freq_dist` with a structural-attribute criteria string
  (e.g. `"doc.author 0"`) already produces the same result through the
  header-declared API, so nothing extra was needed for that case. New
  shim: `mtc_freq_dist_open`/`_count`/`_get_word`/`_get_freq`/`_get_norm`/
  `_close` — a "count + index-based getters" shape (like
  `mtc_corpus_attr_name`) rather than a step-iterator, since `freq_dist`
  computes its whole result up front; the shim sorts by frequency
  descending itself, since `freq_dist` returns bins in unspecified
  `unordered_map` order.
- `ManateeKit/Sources/ManateeKit/LiveConcordance.swift` gained
  `AssociationMeasure` (a curated subset of `bgr_*` codes with real KonText
  UI usage: logDice/MI/MI³/T-score/log-likelihood/Dice — the shim accepts
  any valid code, so this can grow later without a shim change),
  `CollocationSpec`/`CollocationItem`, `FrequencyCriterion`/`FrequencyItem`,
  and `LiveConcordance.collocations(_:)`/`frequencyDistribution(_:minFrequency:)`.
- Tests: `ManateeKit/Tests/ManateeKitTests/CollocationTests.swift`,
  `FrequencyDistributionTests.swift` — including a hand-verified exact
  logDice value (`14 + log2(2*f_AB/(f_A+f_B))`, where `f_B` is the *node*
  concordance's line count, not the collocate's own frequency — got this
  backwards on the first attempt and had to fix the test, not the shim,
  once the real computed value (12.678...) proved correct by hand).

**Real bug found and fixed along the way (2026-09-06, unrelated to Phase 3
itself):** running the full `swift test` suite deleted a real subcorpus
(`year="2021"`, created during Phase 2's manual verification) from
`~/Library/Application Support/Corpora/Subcorpora/testcorp/`. Root cause:
`TestCorpusFixture.corpusName` was also `"testcorp"` — the exact same name
as the real dev corpus — and `SubcorpusTests.tearDown()` unconditionally
deletes `SubcorpusStore.directory(for:)` for that name, a real, permanent,
shared location, not the fixture's own temp directory. Fixed by renaming
the fixture's corpus to `"mkittest"`, which can never collide with a real
corpus name again. Recovering the lost subcorpus just means recreating it
via "New Subcorpus…" the same way as before — it was disposable
verification data, not anything load-bearing.

### AppKit UI

- Two new toolbar buttons on `ConcordanceWindowController`
  ("Collocations"/"Frequencies"), each opening a config sheet
  (`CollocationSheetController`/`FrequencySheetController`, modeled
  directly on `FilterSheetController`'s structure) that populates its
  attribute picker from `Corpus(name: document.corpusName).info()` —
  exactly `NewConcordanceSheetController.refreshForSelectedCorpus`'s
  existing pattern, no new plumbing needed. Wired in
  `ConcordanceViewController.collocationsTapped`/`frequenciesTapped`.
- `ConcordanceDocument` now **retains its current `LiveConcordance`**
  across replays (`private var liveConcordance`) instead of letting it fall
  out of scope once KWIC lines are fetched, as it did through Phase 2 — the
  necessary foundation for either new feature to have a live handle
  reflecting the document's actual current sort/filter/sample/line-group
  state to run against. Exposed via `ConcordanceDocument.collocations(_:)`/
  `frequencyDistribution(_:minFrequency:)`, both throwing
  `AnalysisError.noResultsYet` if called before any query has succeeded.
- Results open in `CollocationWindowController`/`FrequencyWindowController`
  (new, one file each, window + view controller together since they're
  small) — plain `NSWindowController`s wrapping a static-snapshot
  `NSTableView` (client-side sort on the already-fetched array + manual
  `reloadData()`, no diffable-data-source machinery needed, unlike the main
  KWIC table). `ConcordanceViewController.auxiliaryWindowControllers` keeps
  them alive while shown (nothing else would - they're not documents, not
  added via `addWindowController`) and drops each entry once its window's
  `willCloseNotification` fires. Deliberately **do not auto-refresh** when
  the underlying concordance changes later - re-running requires reopening
  via the toolbar button, consistent with the "disposable, re-run anytime"
  decision above.
- Collocations/Frequencies stay enabled even when line groups are active
  (same rationale as the Operations button - they're read-only queries
  against the current view, not new mutating operations, so they don't
  conflict with an active line-group view the way a fresh sort/filter/
  shuffle/sample would).

Verified: `cd ManateeKit && swift test` → 25/25 passing;
`xcodebuild -scheme Corpora clean build` → **BUILD SUCCEEDED**, zero new
warnings; `xcodebuild -scheme Corpora test` → 8/8 `CorporaTests` passing.

**2026-09-06, manually click-tested end-to-end (user):** both toolbar
buttons, attribute/measure/window fields, column-header sorting, closing/
reopening, and quit-anytime-no-prompt behavior all confirmed working
against the dev corpus (`[tag="NN"]` → 30 hits, since the dev corpus's
`morning`/`valley` filler is also tagged NN alongside the 10 real target
nouns - not a bug, just this corpus's construction). One result initially
looked surprising - collocations at window `-1..0` returned only `that`
and `some`, both scoring an identical 13.000 - but this is exactly correct:
`that` precedes every `morning` hit (cnt=10) and `some` precedes every
`valley` hit (cnt=10), both with corpus-wide freq=10, while each real
adjective (brown/lazy/curious/...) only co-occurs once and is correctly
filtered out by the sheet's default Min. collocation frequency = 3.
Hand-verified: `14 + log2(2*10/(10+30)) = 13.0` exactly, using `f_B` =
`viewsize()` = 30 (total `[tag="NN"]` hits) and `N` = 150 (corpus size) -
confirms the shim's math is correct, not a coincidence. Lowering Min.
collocation frequency to 1 surfaces the individual adjectives too, each
with freq=1, cnt=1, as expected. The one skipped item (running Collocations/
Frequencies before any successful query, to see the `AnalysisError.
noResultsYet` alert) turned out to be unreachable via the UI - canceling
the initial "New Concordance" sheet closes the window instead, which is
existing, correct, pre-Phase-3 behavior (a blank document has nothing to
show) - the error path itself is still covered by
`CollocationTests.testCollocationsThrowsForUnknownAttribute`-style
automated tests, just not reachable this particular way by hand.

## Phase 4 — Corpus import & memory residency (engine + AppKit UI done)

Full plan (research, decisions) is preserved at
`/Users/stranak/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/plans/ethereal-scribbling-yeti.md`
from the planning session — this section is the as-built summary. Prompted
by two things: (1) adding a corpus meant hand-writing a registry file and
running `encodevert` from a terminal — not what a native macOS app should
require — and (2) on very high-RAM hardware (the user's own example: a Mac
Studio with 512GB), Manatee's default `mmap`-and-let-the-OS-page-cache-
handle-it behavior leaves that RAM mostly idle for a corpus that would
easily fit resident.

**Confirmed with the user before building:** memory residency is
best-effort warming (`mmap` + `madvise(MADV_WILLNEED)`), not true `mlock` —
no special entitlements, always safe/reversible, no risk of starving the
system if a free-memory estimate is ever wrong. Corpus import auto-detects
attributes/structures by sniffing the vertical file, pre-filling an
editable form rather than requiring the schema to be hand-described.

### Part A — Import (`ManateeKit`)

- `CompiledCorpusStore.swift` (new, mirrors `SubcorpusStore.swift`'s
  pattern): a configurable base directory (env-var-mediated —
  `CORPORA_COMPILED_CORPORA_DIRECTORY`, same design as `CorpusRegistry`
  reading `MANATEE_REGISTRY`, keeping ManateeKit free of a UserDefaults
  dependency) that **doubles as a real Manatee registry directory** — one
  registry file per corpus directly inside it (required for Manatee's own
  registry scan, which skips subdirectories entirely), with the actual
  compiled binary indices and a small JSON metadata sidecar tucked into a
  `.indices/<name>/` subdirectory instead (invisible to that scan, keeps
  the visible directory just "one file per corpus"). This means an imported
  corpus needs no separate wiring to appear in the New Concordance picker.
- `CorpusImporter.swift` (new): `sniffSchema(verticalFile:)` reads up to
  50,000 lines (not the whole file — real vertical files can be billions of
  lines, and structures/columns are expected to appear and repeat early) via
  `URL.lines`, using `Regex(pattern:)` construction rather than regex
  *literal* syntax (`/pattern/`) — the literal syntax didn't parse
  unambiguously in a `guard`/`wholeMatch(of:)` position here, so this had to
  be switched during implementation. `importCorpus(...)` writes the
  registry text (same format `TestCorpusFixture`/`build-dev-corpus.sh`
  already hand-write) and drives `encodevert` as a subprocess, forwarding
  its output line-by-line for a log-style progress UI (its own output isn't
  a documented, parseable percentage, so indeterminate progress + visible
  log is the honest MVP) and supporting cancellation.
- `AppSettings` gained `compiledCorporaDirectory` and
  `minimumFreeMemoryAfterResidency` (default 10 GB). **Real subtlety found
  while wiring this up:** `applyEnvironment()` used to no-op entirely when
  `corpusRegistryDirectories` was empty, specifically so the Xcode scheme's
  own `MANATEE_REGISTRY` (pointing at `DevCorpus`) kept working until a real
  preference was set. Naively always including the compiled-corpora
  directory would have broken that by unconditionally overwriting
  `MANATEE_REGISTRY`. Fixed by merging on top of whatever's already in the
  environment (reading it back via `ProcessInfo`) rather than replacing it —
  imported corpora and the Xcode dev corpus now both just work,
  simultaneously.
- UI: a new **Corpora** Settings pane (`CorporaSettingsViewController.swift`,
  wired into `SettingsWindowController`) with a compiled-corpora directory
  picker, a table of imported corpora, and an Import button opening
  `CorpusImportSheetController.swift` — vertical-file picker, then a
  pre-filled, editable schema form (name field, comma-separated attributes,
  one-structure-per-line `name: attr1, attr2` text), then a progress sheet
  (indeterminate spinner + scrolling log + Cancel) while `encodevert` runs.

### Part B — Memory residency (`ManateeKit`)

- `CorpusMemoryResidency.swift` (new) — deliberately has **no dependency on
  CManatee/manatee-open**: warming works by `mmap`ing and
  `madvise(MADV_WILLNEED)`-ing whatever files sit under a compiled corpus's
  data directory directly, independent of Manatee's own separate `mmap` of
  those same files at query time (both are `MAP_SHARED`, so they share the
  same underlying page-cache pages — no engine change needed).
  `availableMemory()` uses `host_statistics64`/`mach_host_self()` (Darwin),
  summing free + inactive + purgeable pages — the same "reclaimable"
  definition Activity Monitor's memory gauge uses. `canKeepResident(...)`
  is factored out as pure arithmetic so it's unit-testable without mocking
  the Mach call. `unwarm(directory:)` (`MADV_DONTNEED`) makes turning the
  toggle off a considerate best-effort "let this go" rather than a no-op.
- Per-corpus `keepResident` lives in `CompiledCorpusStore`'s metadata
  sidecar (corpus-scoped data), not `AppSettings`.
- UI: each row's "Keep in Memory" checkbox in the Corpora settings pane is
  disabled (with an explanatory tooltip) when enabling it now would leave
  less than `minimumFreeMemoryAfterResidency` free — recomputed on a 2s
  timer while the pane is visible, alongside a simple two-color
  `MemoryBarView` (total vs. currently-available, no charting library) and
  the editable minimum-free-GB field.
- `CorpusResidencyManager.swift` (new, `AppDelegate.applicationDidFinishLaunching`
  calls its `start()`): re-checks `canKeepResident` against *current*
  available memory for every `keepResident`-flagged corpus at launch
  (available memory can differ session to session) and warms only those
  that still pass, skipping (with an `NSLog`, not a blocking alert) any that
  don't; also registers a `DispatchSource.makeMemoryPressureSource`
  observer that proactively `unwarm`s every resident corpus on a `.critical`
  system memory-pressure event, as a safety net for a mechanism that's only
  ever a hint in the first place.

### Tests

`ManateeKit/Tests/ManateeKitTests/CorpusImporterTests.swift` (schema
sniffing against a hand-written vertical fixture; a full import-then-query
round trip through a real `encodevert` run) and
`CorpusMemoryResidencyTests.swift` (`directorySize` against known file
sizes; `canKeepResident`'s arithmetic against fabricated numbers, not the
real Mach call; `warm`/`unwarm` don't throw against real files;
`availableMemory()` is positive and ≤ `totalMemory`).

Verified: `cd ManateeKit && swift test` → 32/32 passing;
`xcodebuild -scheme Corpora clean build` → **BUILD SUCCEEDED**, zero
warnings; `xcodebuild -scheme Corpora test` → 8/8 `CorporaTests` passing.

**2026-09-06, first real-corpus import attempt, three real bugs found and
fixed (user):** importing a genuine large corpus (SYN2025, a Czech National
Corpus release — 162,056,171 lines) instead of a toy fixture immediately
surfaced problems a small dev corpus never would. `encodevert` itself
crashed (signal 6/SIGABRT) somewhere past line ~130,000,000 — cause still
**unexplained** (see below) — but getting to a diagnosable state took three
rounds of fixes to this app's own import UI:

- **Real bug (first suspected, corrected after user clarification): a
  main-actor-blocking `Task`.** `CorpusImportSheetController.compileTapped()`
  originally ran the import inside `Task { @MainActor in ... }`, but
  `CorpusImporter.importCorpus` calls `Process.waitUntilExit()`
  synchronously — exactly the blocking call its own doc comment already
  warned callers to keep off the main actor. Initially suspected as the
  cause of a "frozen window," but the user clarified the window was
  actually **scrolling progress live and correctly the entire run** — the
  freeze only happened *after* the crash. Fixed anyway (switched to
  `Task.detached(priority: .utility)` with explicit `await MainActor.run
  { }` hops for UI updates) since it's a real bug regardless, just not the
  one actually observed here.
- **Real bug, this one matching what was actually seen: unthrottled
  per-chunk UI updates corrupted the text view's rendering.** The
  screenshot the user shared showed a garbled, overlapping mess of
  repeated/smeared text — not a frozen window, a *corrupted* one. Root
  cause: `onProgress` hopped to the main actor and appended directly to the
  `NSTextView` plus called `scrollToEndOfDocument` **on every single output
  chunk**, with no bound on how large the view's content could grow.
  `encodevert`'s output rate is unbounded — something going wrong partway
  through very likely made it spew output (plausibly the same structural
  warning repeating against a degenerate section of the file) far faster
  than one-relayout-per-chunk could keep up with, which visibly corrupts
  `NSTextView` rendering rather than just lagging behind. Fixed with a
  `LogBuffer` (`CorpusImportSheetController.swift`) that `onProgress` just
  appends to cheaply, drained into the view by a fixed 0.2s `Timer` instead
  of once per chunk, with the displayed text itself capped at 200,000
  characters (`maxDisplayedLogLength`) regardless of how much output
  actually arrives.
- **Real bug: the final chunk of `encodevert`'s output could be lost from
  the error message entirely**, independent of the UI corruption above.
  `Pipe`'s `readabilityHandler` drains asynchronously on a GCD-managed
  queue and races with `waitUntilExit()` returning — the original code
  read the accumulated output immediately after, with no guarantee the
  handler had drained the last bytes yet, so the single most useful part
  (whatever's right next to a crash) could be silently missing. This is
  likely why the user's first failure report showed only encodevert's
  memory-estimate line. Fixed by explicitly draining `readToEnd()` after
  `waitUntilExit()` and after nil-ing the handler, before building the
  error; `OutputCollector` (`ManateeKit/CorpusImporter.swift`) also now
  caps retained text (keeping the tail) rather than growing unbounded, for
  the same "unbounded output rate" reason as the `LogBuffer` fix above.
- Also added: distinguishing a **crash** (`terminationReason ==
  .uncaughtSignal` — `CorpusImportError.encodevertCrashed`, with a decoded
  signal name like `SIGABRT`) from a **deliberate nonzero exit**
  (`.encodevertFailed`) — `Process.terminationStatus` is overloaded to mean
  either an exit code or a signal number depending on `terminationReason`,
  and the original code only ever reported the raw number under one label
  regardless of which it actually was.

None of this is specific to SYN2025 or a `manatee-open`/`encodevert` defect
— it's exactly the kind of thing that only shows up once you stop testing
with tiny fixtures. The actual `encodevert` crash is **still unexplained**
— none of the output captured so far (a non-fatal warning about an empty
`<s>` structure around line 35,503,184, which processing continues right
past) points at a specific cause, and the corrupted-rendering bug meant the
actual tail of the log — the part that would show it — was never legible.
Re-running the import with these fixes should surface the real output live,
intact, and legible; **this needs to happen before Phase 4 can be
considered manually verified.**

Verified (that round): `cd ManateeKit && swift test` → 32/32 passing;
`xcodebuild -scheme Corpora clean build` → **BUILD SUCCEEDED**, zero
warnings; `xcodebuild -scheme Corpora test` → 8/8 `CorporaTests` passing.

**2026-09-06, screenshot showed real UI corruption (not a freeze), plus a
"can't quit" bug — progress UI reworked, both fixed:** the user clarified
the window was scrolling progress live and correctly the *entire* run; the
freeze/garbled-text screenshot only happened *after* the crash. Root cause
of the corruption: `onProgress` appended every single output chunk directly
to the `NSTextView` and called `scrollToEndOfDocument` per chunk, with no
cap on content size — if something near the crash made `encodevert` spew
output far faster than that (plausibly the same structural warning
repeating against a degenerate section of the file), `NSTextView`'s
rendering visibly corrupts rather than just lagging. Separately, the user
also couldn't quit the app afterward and had to force-kill it from Xcode —
which also surfaced a real correctness gap: quitting the app didn't
terminate an in-progress `encodevert` subprocess at all, which could have
kept running orphaned. Used the opportunity to rework the whole progress UI
properly rather than just patch the symptom, since the user separately
asked for a real progress bar + collapsible log, and pause/cancel controls
matching the macOS "gold standard":

- `CorpusImporter.countLines(verticalFile:)` (new) — a fast pre-pass
  counting raw `\n` bytes (not UTF-8 line decoding, which `sniffSchema`
  already does but is too slow to run over hundreds of millions of lines) -
  I/O-bound, not CPU-bound, so it stays fast even on a multi-GB file. Lets
  the progress UI show a real determinate "N / total (X%) processed"
  instead of an indeterminate spinner.
- `LogBuffer` (`CorpusImportSheetController.swift`) now also parses the
  latest "Processed N lines" out of each chunk (off the main actor, where
  `onProgress` is actually called - a flood of output shouldn't turn into a
  flood of regex work on the main thread either) alongside the existing
  rate-limited raw-text buffering. A single 0.2s timer drains both into a
  progress bar/status label and the (still-capped-at-200,000-characters)
  raw log.
- The raw log is now collapsed behind a "Show Log"/"Hide Log" disclosure
  toggle, animating the sheet's size via `preferredContentSize`/
  `NSWindow.animator().setContentSize` - matches the classic macOS
  progress-dialog pattern (Installer.app, Software Update): a progress bar
  and status line by default, full detail on demand, not forced on everyone
  all the time.
- **Cancel is now Cmd-. as well as a button** - the standard macOS "stop
  this operation" key equivalent (distinct from Escape, which the schema
  form's own Cancel already used).
- **Pause/Resume**, via a new `CorpusImporter.ImportHandle` (handed to a new
  `onStart` callback once the subprocess is actually running) wrapping
  `Process.suspend()`/`.resume()` (SIGSTOP/SIGCONT under the hood) -
  `encodevert` has no cooperative pause protocol of its own, but suspending
  the whole process works for any subprocess.
- **Real bug fixed: quitting the app didn't stop an in-progress import.**
  `CorpusImportSheetController` now observes
  `NSApplication.willTerminateNotification` and cancels its active import
  task on it, which (via the existing `withTaskCancellationHandler`)
  synchronously sends `encodevert` SIGTERM before the app process actually
  exits - quitting mid-import (menu, Cmd-Q, or the Dock) no longer leaves an
  orphaned subprocess running, and no longer requires a force-kill from
  Xcode to recover from.

Verified (that round): `cd ManateeKit && swift test` → 33/33 passing;
`xcodebuild -scheme Corpora clean build` → **BUILD SUCCEEDED**, zero
warnings; `xcodebuild -scheme Corpora test` → 8/8 `CorporaTests` passing.

**2026-09-06, second real-corpus attempt (SYN2025 again), three more real
issues found via screenshots + confirmed-good control test (user):** tested
the reworked progress UI against SYN2025 again, plus separately confirmed
the small dev corpus (`Corpora/DevCorpus/vert`) imports with no problems at
all - an important data point, since it pointed straight at scale/content
as the trigger rather than the import feature being broken outright.

- **Real bug, the serious one: the sheet's window grew to an enormous,
  mostly-blank height, pushing Cancel off-screen** (screenshot: a window
  ~2600pt tall with the buttons unreachable without raising screen
  resolution) - and separately, a second screenshot showed the schema
  review form and the compile log rendering **overlapping** in the same
  space. Root cause, found by reasoning through the two screenshots
  together with the "dev corpus is fine, SYN2025 isn't" data point: `
  progressLog`/`structuresView` were bare `NSTextView()` instances used as
  `NSScrollView` document views without the standard-but-easy-to-forget
  setup (`widthTracksTextView`, `isVerticallyResizable`, etc.) - without it,
  long unwrapped lines (real absolute paths like `/Users/.../
  CompiledCorpora/.indices/syn2025/data/doc.title`, which only pile up in
  volume once a corpus has 20+ attributes the way SYN2025 does and the tiny
  dev corpus doesn't) don't wrap and can make the text view grow without
  bound instead of staying clipped to its scroll view, dragging the whole
  sheet's layout along with it. Fixed the actual configuration
  (`CorpusImportSheetController.configureForScrolling(_:)`, applied to both
  text views) *and*, as a hard backstop regardless of root cause: the sheet
  no longer resizes itself at all - `fixedContentSize` is set once and never
  changed again; the log disclosure toggle now only animates a constraint
  within that fixed size, never `NSWindow.setContentSize`. Also added
  `showForm()`/`showProgress()` as the only two places allowed to touch
  `formStack`/`progressStack` visibility, so the two can no longer
  desync and overlap the way they did.
- **Real gap, not a bug: `sniffSchema` missed two real structures**
  (`text`/`p`, per the user cross-referencing SYN2025's own published
  documentation) - confirmed as a genuine limitation of scanning only the
  first N lines of an arbitrarily large, heterogeneous file (some
  structures apparently don't appear within the first 50,000 lines of this
  particular corpus). Increased the default scan window 10x (50,000 →
  500,000 lines) to reduce how often this happens, documented plainly that
  no bounded scan can *guarantee* completeness, and leaned on the schema
  form already being fully editable as the actual fix for whatever a scan
  still misses - which is exactly how the user already worked around it
  (per the wiki cross-reference in their report).
- **Real inefficiency, now fixed:** `countLines` re-scanned the whole
  vertical file from scratch on every Compile click, including retries on
  the *same, unchanged* file after a cancel. Added `LineCountCache`
  (`ManateeKit/CorpusImporter.swift`), keyed by file size + modification
  date (cheap to check, correctly invalidates if the file is ever actually
  replaced) - a second attempt on an unchanged file is now instant instead
  of re-reading a multi-GB file again.
- **Also implemented (agreed separately in this session):** quitting the
  app while an import is running now shows a confirmation
  (`AppDelegate.applicationShouldTerminate` + new `ActiveImportTracker`) -
  a deliberate, narrow exception to the app's otherwise-unconditional
  "closable at any time, no questions" rule from Phase 3/4's earlier work,
  justified specifically because a real import can represent hours of
  unrecoverable compute, unlike every other disposable window in this app.

Verified (that round): `cd ManateeKit && swift test` → 34/34 passing;
`xcodebuild -scheme Corpora clean build` → **BUILD SUCCEEDED**, zero
warnings; `xcodebuild -scheme Corpora test` → 8/8 `CorporaTests` passing.

**2026-09-06, investigated the two warnings visible in the SYN2025 log
screenshots, plus revisited the 41 Xcode build warnings (user):**

- Traced both encodevert warnings from the earlier screenshot to their
  source in `manatee-open/src/encodevert.cc`. `"opening structure (s) on
  the same position, ignoring the previous empty one"` is
  `err_open_same_str`, part of `encodevert`'s own `enc_err` framework for
  tolerating messy real-world corpus data - **not** a sign of impending
  failure. `"sh: mkregexattr: command not found"` / `"ERROR: failed to
  create regular expression attribute ..."` traced to
  `compile_regexopt()` (`encodevert.cc:303-315`) - explicitly an
  **optional** per-attribute regex-query speedup (`mkregexattr`, a
  separate tool built alongside `encodevert` in the same directory), not a
  correctness step; the call is wrapped so failure is logged and skipped,
  never fatal. Neither explains the still-unexplained SIGABRT crash from
  earlier, but the `mkregexattr` gap was a real, fixable bug on this app's
  side: `CorpusImporter.importCorpus` launched `encodevert` without a
  `PATH` containing the directory `mkregexattr` actually lives in (only
  found via `encodevert`'s own internal `system("mkregexattr ...")` call),
  so it could never succeed. Fixed by prepending manatee-open's `src/`
  directory to the child process's `PATH`.
- **Real, if cosmetic, finding on a re-ask about the 41 Xcode build
  warnings**: turned out to be worth revisiting - all 38 "object file...
  was built for newer macOS version (26.0/27.0) than being linked (13.0)"
  linker warnings plus the `libpcre2` one were a genuine, easily-fixable
  deployment-target mismatch, not something to just live with. This
  machine runs macOS 27.0; `Corpora/project.yml` still declared a "13.0"
  deployment target left over from early dev-machine-agnostic assumptions
  that no longer apply to an explicitly single-machine, dev-only app.
  Raised both `deploymentTarget.macOS` and `MACOSX_DEPLOYMENT_TARGET` to
  "27.0" (covers every object file's stated minimum) - **41 warnings down
  to 6**, the remaining 6 being the already-assessed-as-low-priority 5
  upstream C++ narrowing warnings plus 1 benign Xcode tooling log line.
  `ManateeKit/Package.swift` still declares `.macOS(.v13)` for standalone
  `swift build`/`swift test` runs from Terminal (a separate build path from
  Xcode's), so those still show the same linker warnings - lower priority
  since matching 26.0/27.0 there needs either a `swift-tools-version` bump
  or a custom version-string API, and it doesn't affect what the user
  actually sees in Xcode.
  - **Still 27.0, deliberately — see "Deployment target / minimum
    toolchain" below**, which records what that costs and how someone on an
    older Xcode works around it.

Verified: `cd ManateeKit && swift build` (compiles; still shows the
Package.swift-side linker warnings, expected) + `swift test` → 34/34
passing; `xcodegen generate` + `xcodebuild -scheme Corpora clean build` →
**BUILD SUCCEEDED**, warning count 41 → 6; `xcodebuild -scheme Corpora
test` → 8/8 `CorporaTests` passing.

**2026-09-06, third real-corpus attempt (SYN2025), the two most important
findings of the whole Phase 4 effort so far (user):**

- **The "final errors and window growth" problem was the exact same root
  cause as the earlier one, just in a different view.** Screenshot showed
  the *form* (schema review) visible again with `Cancel`/`Compile` buttons -
  meaning the error-catch path had run - with log content bleeding in below
  it, in a very tall window. Root cause: `errorLabel` was a plain
  `NSTextField(wrappingLabelWithString:)` with **no height cap of its own**,
  showing up to 4,000 characters of raw error text; `compileButton` was
  pinned to it with `greaterThanOrEqualTo`, so a long error message forced
  Auto Layout to grow the actual window to fit it - the exact class of bug
  the earlier `fixedContentSize` change addressed for the *progress* log,
  but this was a completely separate view that needed the identical
  treatment. Fixed by replacing `errorLabel` with a fixed-height (80pt),
  scrollable `NSTextView` (`errorScroll`/`errorTextView`, same
  `configureForScrolling` helper as the other two text views) and changing
  `compileButton`'s constraint to a fixed `equalTo` offset from it - no
  longer content-dependent, so no message length can force window growth
  again.
- **Real data corruption bug, found by actually querying the result**:
  the compiled corpus looked plausible (7.4GB, 1,848 index files in
  `.indices/syn2025/data/` - the "2KB `syn2025` file" the user found was
  just the small registry text file; the real compiled data lives in that
  hidden, dot-prefixed directory Finder doesn't show by default) but
  querying `[word="the"]` via `manateekit-cli` returned nonsense text that
  wasn't "the" at all. Root cause: `CorpusImporter.importCorpus` never
  wiped the target data directory before compiling - `encodevert` writes
  *into* whatever's already there. The user had retried the same corpus
  name after editing the schema (adding `text`/`p`, missed by the initial
  scan), so the second, different-schema compile's files ended up mixed
  with the first attempt's incompatible leftovers, producing exactly the
  kind of mismatched-lexicon corruption observed. Fixed by wiping the data
  directory (`try? FileManager.default.removeItem`) immediately before
  recreating it in `importCorpus` - every compile now starts from a
  genuinely clean slate, and (usefully) this self-heals the already-corrupt
  `syn2025` on disk automatically the next time it's compiled, no manual
  cleanup needed. New regression test
  (`testImportCorpusWipesStaleFilesFromAPreviousAttempt`) plants a fake
  leftover file and asserts it's gone after a fresh import.
- Confirmed non-fatal, again, on direct re-ask: the `mkregexattr` warning
  in the pasted log is the same already-diagnosed optional-optimization
  failure from earlier this session (fixed via the `PATH` change) - the
  pasted log's timestamp predates that fix reaching a rebuilt app.

Verified: `cd ManateeKit && swift test` → 35/35 passing (new stale-file
test included); `xcodebuild -scheme Corpora clean build` → **BUILD
SUCCEEDED**, still 6 warnings (unchanged, expected); `xcodebuild -scheme
Corpora test` → 8/8 `CorporaTests` passing.

**2026-09-06/07, fourth real-corpus attempt (SYN2025) — the original SIGABRT
crash finally explained, plus the hidden-directory design reversed (user):**
the user hand-deleted the old `syn2025` + `.indices/syn2025` and re-ran the
compile from scratch. It still crashed, but the errorScroll fix above meant
the **complete** crash text was visible for the first time:
`libc++abi: terminating due to uncaught exception of type std::runtime_error:
renaming '.../data/word.lex.tmp' to '.../data/word.lex': No such file or
directory` — immediately preceded in the log by *two* separate "Closing
attribute .../word ..." lines.

- **Root cause found: a duplicate `ATTRIBUTE word` registry declaration.**
  `CorpusImporter.makeRegistryText` always emits `ATTRIBUTE word` as its
  first attribute line (mandatory - every Manatee corpus has a `word`
  positional attribute), then appended one `ATTRIBUTE <x>` line per entry in
  the caller-supplied `attributes` array with no de-duplication. The user's
  own "Positional attributes" field content (visible in an earlier
  screenshot) was `word, sword, lemma, sublemma, tag, pos, case, verbtag,
  ord, afun, parer...` — reasonably including "word" as the literal name of
  their vertical file's own first column. The generated registry therefore
  declared `ATTRIBUTE word` **twice**. `encodevert` builds one `write_attr`
  object per registry `ATTRIBUTE` line (`encodevert.cc` lines ~979-1013),
  so this produced two independent writers both targeting the identical
  output path (`data/word.lex`): the first finishes cleanly and renames its
  `.tmp` file into place (matching the 18MB `word.lex` the user found
  intact on disk); the second, redundant writer then tries to rename the
  *same already-consumed* temp path and throws an uncaught
  `std::runtime_error`, aborting the whole process. This also explains the
  `[word="..."]` query mismatches reported against SYN2025 (screenshot:
  querying `moci` matched `Vytřepala` with garbled surrounding context) —
  the abort happened before later corpus-finalization steps could run,
  leaving `word`'s index out of sync with the rest. Fixed by skipping
  `"word"` when appending the caller-supplied `attributes` list in
  `makeRegistryText` (`ManateeKit/CorpusImporter.swift`) - a user who types
  "word" into the Positional Attributes field is now safely ignored there
  rather than producing a broken registry. `makeRegistryText` is no longer
  `private` (just internal) so a new regression test
  (`testMakeRegistryTextDoesNotDuplicateAttributeWordWhenCallerIncludesIt`)
  can assert the generated text contains exactly one `ATTRIBUTE word`
  occurrence when the input list also contains `"word"`.
- **Explicit, repeated user instruction acted on: no hidden directories for
  anything user-facing.** *"do NOT put files into hidden directories I
  cannot find. It is especially confusing when in the GUI of Settings/
  Corpora you clearly say that ... CompiledCorpora is the directory for the
  actual compiled corpora."* `CompiledCorpusStore` previously hid each
  corpus's compiled binary indices inside a dot-prefixed `.indices/<name>/`
  subdirectory of the compiled-corpora base directory - exactly the kind of
  Finder-invisible location this project's own established convention
  (`Corpora/DevCorpus/`, deliberately not `.devcorpus/`) says to avoid.
  Changed to a **visible** sibling directory, `<base>/<name>.data/` (a
  trailing `.data` *suffix* on the name, not a leading dot - only a name
  that *starts* with a dot is hidden by macOS). `dataDirectory(for:)`,
  the metadata sidecar, and `remove(_:)` all updated accordingly; Manatee's
  own registry scan already skips directories regardless of name, so this
  needed no change on that side. `CorpusImporterTests`'s stale-file
  regression test now calls `CompiledCorpusStore.dataDirectory(for:)`
  directly instead of hardcoding the old `.indices/...` path.
- **Not yet addressed (user feedback, lower priority):** "it is not
  intuitive that after the failure it gets to the window state allowing it
  to just re-run again" - i.e. a failed compile reverts to the editable
  schema form rather than something more clearly signaling failure. Current
  behavior is deliberate (so a retry doesn't require re-filling the whole
  form) but the presentation could be clearer; not changed this round.

Practical guidance for the next re-import: the existing on-disk `syn2025`
remnants (under the old `.indices/` location, already partially hand-cleaned
by the user) are superseded by this change and can be deleted -
`CompiledCorpusStore` now writes to `<base>/syn2025.data/` instead. A fresh
compile should no longer crash even with "word" left in the Positional
Attributes field, since it's now filtered out rather than causing a
duplicate declaration.

- **Follow-up hardening (user asked directly): validate declared attribute
  count against the vertical file's real column count, and refuse to
  compile on a mismatch** rather than relying solely on the "word"-specific
  filter above. The "word" fix only catches that one specific name
  collision; a user could still miscount in other ways (too few/too many
  entries in the Positional Attributes list) and previously nothing caught
  it before `encodevert` ran - either silently misassigning columns to the
  wrong attributes, or crashing if the miscount happened to duplicate an
  existing name. Added `CorpusImporter.firstDataLineColumnCount(verticalFile:)`
  (reads just the first non-structure, non-blank line) and a check at the
  very top of `importCorpus`, before any disk state is touched: `1 +
  attributes.filter { $0 != "word" }.count` (the actual declared-attribute
  total once the "word" fix's de-dup is applied) must equal the file's real
  tab-separated column count, or `importCorpus` throws
  `CorpusImportError.attributeCountMismatch(declared:actualColumns:)` with a
  message telling the user exactly how many entries their Positional
  Attributes list needs. Surfaces through the existing generic
  `showFormError("\(error)")` catch site in
  `CorpusImportSheetController` with no UI changes needed, since
  `CorpusImportError` is `CustomStringConvertible`. New regression test
  `testImportCorpusRefusesToCompileWhenDeclaredAttributesDontMatchFileColumns`
  (declares one attribute for a 3-column file, asserts the specific error
  and that no registry file gets written).

Verified: `cd ManateeKit && swift test` → 37/37 passing (new
`testMakeRegistryTextDoesNotDuplicateAttributeWordWhenCallerIncludesIt` and
`testImportCorpusRefusesToCompileWhenDeclaredAttributesDontMatchFileColumns`
included); `xcodebuild -scheme Corpora build` (via `BuildProject`) →
**BUILD SUCCEEDED**; `xcodebuild -scheme Corpora test` (via `RunAllTests`)
→ 8/8 `CorporaTests` passing.

- **`countLines` benchmarked against `wc -l` on the user's suspicion it
  might be faster, and rewritten once the numbers said otherwise (user).**
  Measured on a synthetic 420MB/40M-line vertical-shaped file (`/tmp`, same
  machine, warm page cache, 3 runs each): `wc -l` ≈0.38-0.40s;
  `countLines`'s then-current `chunk.reduce(0) { ... }` byte-by-byte closure
  ≈1.74-1.97s — over **4x slower** than `wc -l`, not faster. Root cause:
  `Data.reduce` invokes its closure once per byte, which dominates over any
  I/O cost at this scale. Rewrote to scan each 4MB chunk with `memchr`
  (`withUnsafeBytes` + a pointer-advancing loop, jumping straight to the
  next newline instead of testing every byte) — re-measured at ≈0.27-0.32s,
  a hair faster than `wc -l` itself. Same chunked-read structure and
  cancellation/caching behavior, only the inner byte-scan changed.

Verified (that round): `cd ManateeKit && swift test` → 37/37 passing
(existing `countLines` tests, unchanged expectations, confirm the rewrite
still counts correctly); `xcodebuild -scheme Corpora build` (via
`BuildProject`) → **BUILD SUCCEEDED**; `xcodebuild -scheme Corpora test`
(via `RunAllTests`) → 8/8 `CorporaTests` passing.

**Still not manually click-tested end-to-end** — re-running the SYN2025
import (a fresh compile, now self-cleaning, with the duplicate-`word` and
hidden-directory bugs both fixed) is the next step, along with the original
Keep in Memory toggle/guard verification. Every concrete, diagnosable
symptom found across this whole Phase 4 effort (the hang, the rendering
corruption, the window growth ×2, the quit/orphan-process bug, the
`mkregexattr` gap, the stale-directory corruption, and now the duplicate-
`word`-attribute crash) has had a real, verified root cause and fix.

### Backlog: corpus Settings UX (not started)

Flagged 2026-09-07 after `syn2025` produced an intermittent bad query
result and the user first assumed it needed a "delete this corpus"
function - see Phase 5.5's inconclusive-bug writeup. Resolved: a delete
function already exists (Settings → Corpora's "−" button, calls
`CompiledCorpusStore.remove(_:)`, which removes the registry file,
compiled indices, and metadata) - the user confirmed that's sufficient
once they knew it was there, and explicitly dropped the "recompile"
idea. One item remains, deferred by the user ("put a pin in it"):

- **Two separate, confusingly-similar corpus lists in Settings** - not
  yet investigated. General's "Corpus registry directories" (`AppSettings
  .corpusRegistryDirectories`, plain search-path strings, Manatee's own
  `MANATEE_REGISTRY` equivalent - see `GeneralSettingsViewController`) vs.
  Corpora's compiled-corpora table (`CompiledCorpusStore`, corpora this
  app itself imported/compiled, with size/residency). The latter's
  `baseDirectory` is one of the former's entries under the hood, but
  nothing in the UI currently explains that relationship.

## Phase 5 — Concordance UX enhancements, KonText-inspired (in progress)

Prompted by the user asking to compare this app's concordance view against
KonText's and add what's missing. Five features, agreed with the user in
this priority order (start → finish):

1. **Adjustable context width** - widen/narrow left/right context live in
   an existing window, not just at document creation.
2. **Query history** - recall recent CQL queries typed in a window/session.
3. **Multi-attribute KWIC display + mouseover** - show e.g. lemma/tag
   alongside word, inline or on hover.
4. **Document/structural info** - a row-detail view showing a hit's
   enclosing `<doc>`/structure attributes (author, year, etc.).
5. **Export concordance** - save visible/filtered lines to text/CSV.

Investigated up front (see the Explore-agent survey this session) what
already exists vs. what's genuinely new scope:

- **KWIC display today** is single-attribute only, all the way down:
  `KWICLine` (`ManateeKit.swift`) is `{ left, kwic, right: String }`, and
  `mtcbridge.cc`'s `join_text_tokens` explicitly discards every attribute
  but plain word text before it reaches Swift - even though the underlying
  manatee-open `KWICLines` class (`concord/concget.hh`) already accepts
  comma-separated multi-attribute strings (`kwica`/`ctxa`) and a
  comma-separated structure list (`struca`) for inline structural
  annotation. So multi-attribute KWIC (#3) and structural info (#4) are
  both "engine already supports it, bridge/Swift/UI layer doesn't yet" -
  real but bounded new work, not a manatee-open change.
- **No tooltip/hover mechanism exists anywhere in this codebase** (grep for
  `NSToolTip`/`toolTip`/`mouseEntered`/`mouseMoved`/tracking areas across
  `Corpora/Corpora` turns up exactly one static `.toolTip` string in a
  Settings checkbox) - #3's mouseover mode is new AppKit groundwork, not an
  extension of an existing pattern.
- **Adjustable context width (#1) needed no engine/bridge work at all**:
  `LiveConcordance.kwicLines(leftContext:rightContext:kwicAttr:)`
  (`LiveConcordance.swift:315`) already takes context sizes as a per-call
  parameter, not something baked into the query at open time, and
  `ConcordanceDocument.leftContext`/`.rightContext` (`ConcordanceDocument.
  swift:22-23`) are already stored, persisted properties - nothing in the
  UI had ever changed them after document creation. Pure UI + a new cheap
  refetch path.
- **Attribute-picker precedent already exists**: `CollocationSheetController`
  populates a real `NSPopUpButton` from `CorpusInfo.attributes`
  (`Corpus.info()`) - the model to extend for a "which attributes to show"
  picker in #3, rather than `SortPopoverController`'s free-text field
  (which doesn't discover attributes at all).
- **No per-window "Display settings" UI pattern exists yet** - only global
  `AppSettings` (UserDefaults-backed) and per-document plain stored
  properties (`kwicAttr`, `leftContext`/`rightContext` themselves). A new
  toolbar popover (mirroring `SortPopoverController`/`SamplePopoverController`'s
  shape) is the natural third pattern, used for #1 and probably #3.

### 5.1 — Adjustable context width (done)

Widens/narrows how many tokens of left/right context each KWIC line shows,
live, in an already-open concordance window - matching KonText's own
expand/narrow-context control rather than only being settable when a query
is first run.

- **`ConcordanceDocument.swift`**: extracted `replay()`'s row-building
  logic (line-group lookup per row + the display-only descending-sort
  reversal) into a shared `static func buildRows(from:live:descendingSort:)`,
  and its "which sort direction is currently active" scan into
  `static func descendingSort(in:)` - both now reused by a new
  `setContext(left:right:)` method. That method updates the stored
  `leftContext`/`rightContext` and, if a `liveConcordance` handle already
  exists, re-fetches KWIC lines from that *same* handle
  (`live.kwicLines(leftContext:rightContext:kwicAttr:)` again) rather than
  calling `replay()` - which would reopen the corpus and re-run the query
  plus every operation in the chain from scratch just to change how much
  context is displayed. `status`'s hit-count/corpus-size text is left
  untouched on a context-only refetch since neither actually changes when
  only context width does. Chained onto the existing `currentReplayTask`
  (the same serialization `replay()` itself uses) so a context change
  racing with an in-flight replay can't interleave.
- Deliberately **not** part of the undoable `operations` chain and **not**
  gated by `hasLineGroups` - mirrors `kwicAttr`'s existing status as a pure
  display setting, not a corpus query operation; widening context doesn't
  change hit order/count and has no reason to conflict with an active line
  group view the way starting a new sort/filter/shuffle/sample would.
- **New `ContextPopoverController.swift`** (mirrors `SamplePopoverController`'s
  shape: two labeled `NSTextField`s + Apply button, transient popover) and
  a new toolbar item (`ConcordanceWindowController`'s `ItemID.context`,
  SF Symbol `arrow.left.and.right`, placed after Sample) wired via
  `ConcordanceViewController.contextTapped(_:)`. Not added to
  `updateToolbarState`'s disable-when-line-groups-exist list, per the point
  above.

Verified: `cd ManateeKit && swift test` (unaffected - no ManateeKit changes
this round); `xcodebuild -scheme Corpora build`/`test` (via `BuildProject`/
`RunAllTests`) → **BUILD SUCCEEDED**, 8/8 `CorporaTests` passing. Not yet
manually click-tested (widen/narrow context in a live window, confirm the
KWIC columns actually grow/shrink and line groups survive) - next step.

### 5.2 — Query history (done)

Recalls recently run CQL queries, across every corpus/window in the app,
from a new toolbar popover - mirrors KonText's own persistent query
history rather than resetting every launch.

- **New `QueryHistoryStore.swift`** (`Corpora/Corpora/Settings/`, alongside
  `AppSettings` - same UserDefaults-backed precedent, though this isn't a
  user-facing settings pane): `QueryHistoryEntry { corpusName,
  subcorpusPath, query, date }`, stored as JSON under one UserDefaults key,
  capped at 200 entries (newest first; oldest silently dropped past that).
  Entries are **unique by (corpusName, subcorpusPath, query)** - `record(...)`
  is an upsert: an existing match anywhere in the list is removed and
  reinserted at the front with a refreshed timestamp, rather than appended
  as a second row. (Changed after manual testing: the first version only
  de-duped an exact repeat of the *immediately preceding* entry, so
  re-running the same favorite query from the History popover kept
  duplicating it at the top instead of just bumping its "last used" time -
  the user caught this and asked for unique-queries-by-last-used instead of
  a linear "historically true" log.) Recorded **unconditionally** at
  submission time (like shell history) rather than only after a successful
  search - "what did I just search for" is still worth recalling even if it
  was a CQL typo, and gating on success would need moving the call into
  `replay()`'s success branch for no real benefit.
- **`ConcordanceDocument.runQuery(_:)`** now calls
  `QueryHistoryStore.record(...)` before `replay()` - since both the
  "New Concordance" sheet's Search button and the persistent query bar's
  re-run already funnel through this one method, no second call site was
  needed.
- **New `HistoryPopoverController.swift`**: a scrollable list of the most
  recent 20 entries (`QueryHistoryStore` itself keeps up to 200 - this is a
  quick-recall list, not a searchable archive), each a full-width clickable
  row showing corpus name + a manually-truncated (60 char) query + a
  relative timestamp (`RelativeDateTimeFormatter`), plus a "Clear History"
  button. Same stack-of-rows shape as `OperationsPopoverController`.
- New toolbar item (`ConcordanceWindowController`'s `ItemID.history`, SF
  Symbol `clock.arrow.circlepath`, placed first/leftmost - logically
  precedes Sort/Filter/etc.) wired via
  `ConcordanceViewController.historyTapped(_:)`: clicking a row loads that
  entry's corpus/subcorpus/query into the current window and runs it via
  the normal `runQuery` path. Not gated by line groups - running a
  different query is always allowed, same as typing into the query bar.
- **New `QueryHistoryStoreTests.swift`** (`Corpora/CorporaTests/`, `Swift
  Testing`/`@testable import Corpora`, matching `ConcordanceOperationTests`'s
  precedent): each test uses a throwaway `UserDefaults(suiteName:)` so
  nothing touches the real `UserDefaults.standard`. Covers newest-first
  ordering, the move-to-front-and-refresh-timestamp upsert, keeping repeats
  that differ by corpus/subcorpus as distinct entries, ignoring blank
  queries, the 200-entry cap keeping the most recent, and `clear()`.
- **Not implemented / explicitly out of scope for this pass**: recalling
  history from the "New Concordance" sheet itself (only an already-open
  window's toolbar can recall history) - a reasonable follow-on if it turns
  out to matter in practice, not done speculatively.

Verified: `xcodebuild -scheme Corpora build`/`test` (via `BuildProject`/
`RunAllTests`) → **BUILD SUCCEEDED**, 14/14 `CorporaTests` passing (6 new).
Not yet manually click-tested (run a few queries, open History, confirm
recall/Clear both work) - next step, same as 5.1's open item.

### 5.3 — Multi-attribute KWIC display + mouseover (done)

Shows secondary positional attributes (e.g. "lemma"/"tag") alongside the
primary word text per token, either inline or via a hover tooltip -
KonText's own "corpus view options" attribute display, in miniature.

**Engine/bridge layer** (the part flagged up front as real, bounded new
work - manatee-open's `KWICLines` already supported multi-attribute output,
`mtcbridge.cc` just discarded everything but the primary word text):

- `ManateeKit/Sources/CManatee/{include/mtcbridge.h,mtcbridge.cc}`:
  replaced `mtc_kwic_get_left/kwic/right` (space-joined, primary attribute
  only) with `mtc_kwic_get_{left,kwic,right}_attr(MTCKwic*, attr_name,
  error)`, callable with *any* attribute name (including whichever one is
  primary) rather than only the one `mtc_kwic_open` was opened with. `MTCKwic`
  now also stores the owning `Corpus*` (needed to look up an arbitrary
  attribute by name via `Corpus::get_attr`, cheap after the first call per
  name - `Corpus::get_attr` itself caches). Implemented directly against
  `PosAttr::textat(Position)`/`TextIterator::next()` over the position
  ranges `KWICLines` already computes and exposes (`get_ctxbeg()`/
  `get_pos()`/`get_kwiclen()`/`get_ctxend()`) - bypasses `KWICLines`'s own
  combined multi-attribute/collocation-tag `Tokens` rendering entirely
  (`get_corp_text`'s `\x1F`-joined-secondary-attribute-per-token format,
  further interleaved with markup tags by `fill_segment`), which would have
  needed correctly re-deriving token boundaries from a fairly intricate,
  markup-and-attribute-mixed generic format. Independently walking each
  attribute's own `PosAttr` over the identical position range sidesteps
  that: same token count and alignment by construction, no markup-tag
  parsing needed (this shim never exposed collocation highlighting anyway).
- **Encoding**: one token per `'\x1F'` (unit separator - can't appear in
  real corpus text, matches manatee's own `get_corp_text`'s attribute
  delimiter convention) with the delimiter placed *before every* token
  including the first (e.g. `"\x1Fthe\x1Ffox\x1Fjumps"`) - not a plain
  *between*-tokens separator. This "leading delimiter" shape is what makes
  decoding unambiguous: a caller drops the first character then splits on
  `'\x1F'` keeping empty pieces, correctly recovering one entry per token
  even when a token's own attribute value happens to be `""` - a plain
  separator (or reusing the old space-joined convention) can't distinguish
  "zero tokens" from "one token with an empty value." An entirely empty
  (`""`) result unambiguously means zero tokens (an undefined/empty line
  segment), since it's the only case with no leading delimiter at all.
- **`ManateeKit.swift`**: `KWICLine` changed from three plain stored
  strings to `{leftTokens, kwicTokens, rightTokens}: [KWICToken]`
  (`KWICToken = {word, secondaryAttributes: [String: String]}`), with
  `left`/`kwic`/`right` now *computed* (`tokens.map(\.word).joined(
  separator: " ")`) for source compatibility with every existing caller
  that only ever read the whole-segment string. Confirmed zero other
  breakage: nothing outside `LiveConcordance.kwicLines` itself ever
  constructed a `KWICLine`, and every other read site (`ConcordanceDocument`,
  `KWICCellView` via `ConcordanceViewController`, both test files) only
  reads `.left`/`.kwic`/`.right`.
- **`LiveConcordance.kwicLines(...)`** gained `secondaryAttributes: [String]
  = []`. Switched to call the new `_attr` getters exclusively (passing
  `kwicAttr` for the primary token text too, not just secondary
  attributes) - one consistent decode path instead of two, and it removes
  a latent (if practically unlikely) risk the old space-joined primary
  getters had: a "word" value containing a literal embedded space would
  have silently misaligned primary-token-count against secondary-token-
  count once both were being zipped together per token. Decode/error
  handling uses nested functions (not `Self.`-scoped helpers) specifically
  so both capture the shared `var error` *by reference* - an earlier draft
  passed `error`'s value as a separate function parameter, which could
  report a stale (usually "unknown error") message instead of the real one
  if a *later* per-attribute call failed after an *earlier* one had
  already succeeded; fixed before it shipped anywhere, but worth recording
  as a real mistake caught during this session, not a hypothetical one.
  Documented cost: N secondary attributes = 3N extra bridge calls per line
  (one per left/kwic/right segment per attribute) on top of the 3 already
  made for `kwicAttr` - fine for the handful of attributes a picker
  realistically requests, but compounds an existing, unrelated scalability
  gap (`kwicLines` fetches every hit up front, unpaginated) - flagged, not
  fixed, in this pass.
- New tests (`LiveConcordanceTests.swift`): word+lemma+tag alignment across
  left/kwic/right against the real fixture corpus (confirms the encoding
  round-trips correctly on the first real attempt - no debugging needed
  once written); secondary attributes stay empty when none are requested
  (no behavior change for existing callers); an unknown attribute name
  throws.

**AppKit UI**:

- **New `KWICFormatter.swift`** (`Corpora/Corpora/Documents/`): pure
  formatting logic, deliberately dependent on neither `ManateeKit` display
  opinions nor AppKit - `displaySegments(for:inlineAttributes:)` (returns
  `[KWICDisplaySegment]`, each tagged `.word` or `.secondaryAttribute` so
  the caller can style them differently, rather than a single opaque
  `String` - see "styling" below) and `tooltipText(for:tooltipAttributes:)`
  (one line per token, `nil` when no tooltip attributes are requested).
  Unit-testable with no live corpus - `KWICFormatterTests.swift`
  (`Corpora/CorporaTests/`) covers both directly against hand-built
  `KWICToken` values.
- **Inline and hover are independent per attribute, not one mode for the
  whole document** - `ConcordanceDocument` has two separate lists,
  `inlineAttributes: [String]` and `tooltipAttributes: [String]` (an
  attribute can be in both, one, or neither), not a single `[String]` +
  shared mode enum. This was a deliberate revision after the user pointed
  out the real use case ("tag inline, lemma on hover, at the same time")
  an either/or `AttributeDisplayMode` couldn't express - caught before
  it needed a second redesign, since it came up in the same review pass as
  the styling/tooltip bugs below. `attributesToFetch` (private, the
  deduplicated union of both lists) is what's actually passed to
  `LiveConcordance.kwicLines(secondaryAttributes:)`, since both lists need
  real per-token values regardless of which one(s) an attribute is
  configured to display through.
- **`ConcordanceDocument.setContext`/`setAttributeDisplay(
  inlineAttributes:tooltipAttributes:)`** both delegate to one shared
  `refetchDisplay()` - both are "re-fetch KWIC lines from the existing
  `liveConcordance` handle, don't replay the whole query/operation chain"
  operations, differing only in *which* stored properties changed first.
  Both lists persisted in `DocumentState` as *optional* fields (a document
  autosaved before this feature existed still decodes).
- **`AttributeDisplayPopoverController.swift`**: one row per corpus
  attribute (except the current primary `kwicAttr`, sourced from
  `Corpus(name:).info().attributes` - the same real-attribute-discovery
  precedent `CollocationSheetController`'s picker already established, not
  free text, so a typo can't reach `kwicLines` and throw), each with two
  independent checkboxes ("Inline" / "On Hover") rather than one shared
  mode control for the whole popover.
- New toolbar item (`ConcordanceWindowController`'s `ItemID.attributes`,
  SF Symbol `textformat`, placed after Context) wired via
  `ConcordanceViewController.attributesTapped(_:)`. Not gated by line
  groups, same reasoning as Context.

**Found via manual testing, both fixed before commit:**

- **Secondary attributes needed distinct styling, not plain inline text.**
  User feedback: "should look different, start with grey. Later we'll make
  a settings panel for that or something." `KWICCellView.configure`
  switched from a plain `NSTextField.stringValue` to building an
  `NSMutableAttributedString` from `[KWICDisplaySegment]` -
  `.secondaryAttribute` segments always render in `.secondaryLabelColor`
  at the plain (non-bold) base font, regardless of the column's own
  style (even in the bold/accent-colored KWIC column) so an inline
  attribute reads as clearly secondary. A single `.word` segment (no
  inline attributes configured, the common case) renders identically to
  the old plain-string behavior. Explicitly scoped as a first pass, not a
  final design - a real display-settings panel (colors, fonts) is future
  work, not attempted here.
- **Hover tooltip showed nothing.** Root cause not fully isolated (no
  interactive AppKit runtime access from this session - see
  `docs/project-plan.md`'s Division of labor - to reproduce and bisect the
  exact mechanism), but the fix applied is a well-known robustness pattern
  for this class of bug: `KWICCellView.configure` now sets `toolTip` on
  *both* the cell view (`self`) and its `label` subview, not just the
  cell. The label visually covers nearly the entire cell, and which of the
  two views AppKit's tooltip tracking actually resolves against isn't
  guaranteed from the cell-view-only approach - setting it on both costs
  nothing and is the standard fix for exactly this symptom. **Not yet
  re-verified interactively** - next manual test should confirm this
  actually resolved it, not just plausibly addresses it.

Verified: `cd ManateeKit && swift test` → 40/40 passing; `xcodebuild
-scheme Corpora build`/`test` (via `BuildProject`/`RunAllTests`) →
**BUILD SUCCEEDED**, 21/21 `CorporaTests` passing (7 `KWICFormatterTests`,
covering the inline/tooltip-attribute-list independence explicitly). Not
yet manually click-tested end to end (open the Attributes popover, check
"tag" Inline and "lemma" On Hover simultaneously, confirm the inline
suffix renders grey, confirm the tooltip now actually appears on hover) -
next step, same as 5.1/5.2's open item, now with the added tooltip
re-verification above.

**Found via manual testing (second round), real row-rendering regression,
fixed:** screenshot showed the Left column's text progressively
overlapping/garbling into an illegible smear further down the table -
worse with each row, not present in the Match/Right columns or in the
`[]`-query screenshot's first few rows. Root cause: switching
`KWICCellView.configure` from `label.stringValue = text` to
`label.attributedStringValue = attributed` (needed for the grey secondary-
attribute styling above) dropped the field's own `lineBreakMode`/
`alignment` properties - `NSTextField.attributedStringValue` does **not**
inherit them from the field the way `.stringValue` does, and silently
falls back to wrapping when the attributed string carries no explicit
paragraph style. Each row's actual rendered content was therefore taller
than what the table view had allocated for it, and the mismatch compounded
scrolling further down - exactly the "increasingly garbled" pattern in the
screenshot. Fixed by baking an explicit `NSMutableParagraphStyle`
(`lineBreakMode`/`alignment` matching what the field property would have
provided) into the attributed string itself, applied across every segment,
plus `label.maximumNumberOfLines = 1` in `setUp()` as a standing safeguard
against this exact class of regression recurring from some future change
to `configure` - not just a fix for today's specific call site.

Verified: `xcodebuild -scheme Corpora build`/`test` (via `BuildProject`/
`RunAllTests`) → **BUILD SUCCEEDED**, 21/21 `CorporaTests` passing
(unaffected - this bug was in rendering, not logic, so no test caught it
and none is expected to from this fix; confirming it's actually resolved
needs the same interactive click-through as everything else in this
phase). Still not manually click-tested - now with three things to check
in one pass: inline/hover combination, grey inline styling, and this
row-overlap fix.

**2026-09-07, manual testing (third round) - hover redesigned to be
per-token, not per-cell; a real, unrelated focus bug found and fixed:**

- User confirmed inline and (whole-cell) hover both rendered, but then
  clarified hover was wrong-grained: "hover should be per word, not whole
  line or left/right context part. Hover specific for each token." The
  whole-cell `self.toolTip`/`label.toolTip` approach from the previous
  round was never going to satisfy this regardless of whether its earlier
  "shows nothing" symptom was actually fixed - it fundamentally couldn't
  distinguish which word was under the cursor. Replaced entirely with
  per-region tooltips via `NSView.addToolTip(_:owner:userData:)`, AppKit's
  actual mechanism for multiple independent tooltip areas within one view:
  - `KWICFormatter.displayLine(for:inlineAttributes:tooltipAttributes:)`
    (replaces the old `displaySegments`/`tooltipText` pair) returns both
    `segments: [KWICDisplaySegment]` (unchanged purpose) and
    `tokenTooltips: [KWICTokenTooltip]`, each tagged with a
    `segmentRange: Range<Int>` - which of that *same* segment list belongs
    to that one token (its word segment, plus its inline-attribute suffix
    segment if it has one). Computed in the same pass as `segments` so the
    two can never drift apart. Still pure/AppKit-free, still unit-tested
    (`KWICFormatterTests` - a new
    `tooltipSegmentRangesPointAtThatTokensOwnSegmentsOnly` test asserts the
    ranges cover exactly that token's own segments, not neighboring ones
    or the whole line).
  - `KWICCellView` converts each token's segment range into an on-screen
    rect by summing individual segment widths (`NSAttributedString(...)
    .size().width` per segment) and applying the column's alignment
    (right/center/left) to find where the text actually starts within the
    label's bounds - exact for this app's monospaced results font (every
    character/weight shares one advance width, so per-segment widths sum
    to the same total the whole string would measure as one unit; a
    proportional font or truncated overflow text would need more care, not
    attempted here). One `addToolTip` call per token registers that token's
    own rect, with `self` as `owner` implementing the informal
    `stringForToolTip` selector to return that specific token's text via
    an index encoded in `userData` (offset by 1, since `bitPattern: 0`
    decodes to a null pointer, indistinguishable from "no userData").
  - This rect math needs the view's *final* size, which isn't reliably
    available at `configure()`-call time for a freshly constructed cell
    (see `ConcordanceViewController.makeCell` - no reuse pool, so every
    cell starts from zero geometry) - moved into an `override func
    layout()`, AppKit's own "geometry is now final" callback, rather than
    computed inline in `configure()`.
- **Separately, unrelated bug**: Cmd-N (new concordance) didn't focus the
  query field - not automatically, and not via mouse click or Tab either.
  Root cause (confirmed by grepping the whole call path for any
  `nextKeyView`/`makeFirstResponder`/`viewDidAppear` and finding none):
  nothing ever explicitly focused it, and `CQLQueryField` (a custom
  `NSScrollView`-wrapping-an-`NSTextView` composite, not a standard
  control) isn't reliably reached by AppKit's *auto-generated* Tab
  key-view loop the way a plain `NSTextField`/`NSPopUpButton` is - Tabbing
  from `subcorpusPopUp` skipped straight to the buttons, over the query
  field entirely. Fixed with two explicit, standard remedies for exactly
  this class of gap: `NewConcordanceSheetController.loadView()` now wires
  `nextKeyView` explicitly (`corpusPopUp` → `subcorpusPopUp` →
  `queryField.textView` → `searchButton` → `cancelButton`), and a new
  `override func viewDidAppear()` calls a new `CQLQueryField.focus()`
  method (`window?.makeFirstResponder(textView)`) once the sheet
  genuinely has a window to focus within (not `loadView()`, which runs
  before that's guaranteed). `CQLQueryField.textView` changed from
  `private` to internal access so both call sites (a different file,
  same module) can reach it. The "mouse click also didn't focus it" half
  of the report is less explained by this fix specifically (a click
  correctly hitting the scroll view/text view should already focus it
  regardless of the Tab-loop issue) - flagged as possibly resolved as a
  side effect of the sheet now reliably having a real first responder
  from the moment it opens, but not separately root-caused; worth
  re-checking specifically on the next manual pass.

Verified: `cd ManateeKit && swift test` → 40/40 passing (unaffected);
`xcodebuild -scheme Corpora build`/`test` (via `BuildProject`/
`RunAllTests`) → **BUILD SUCCEEDED**, 22/22 `CorporaTests` passing (8
`KWICFormatterTests`, including the new segment-range-isolation test).
Not yet manually click-tested - the per-token hover redesign and the
Cmd-N focus fix are both new since the last interactive pass.

**2026-09-07, manual testing (fourth round) - the `addToolTip`-based hover
mechanism above still showed nothing, replaced with a different AppKit
mechanism entirely:** user specified one attribute inline, a different one
on hover; inline rendered correctly, hover still showed nothing at all
(not "wrong-grained" this time - genuinely absent, same as the very first
report). Rather than keep guessing at what specifically was wrong with
`addToolTip(_:owner:userData:)`-based per-region registration (plausible
suspects considered: `layout()` may not fire reliably for a freshly
constructed, not-yet-windowed `NSTableCellView`; `needsLayout = true` set
before the view has a window may not be honored once it gets one - neither
confirmable without interactive AppKit access), switched to a mechanism
that sidesteps the whole class of "was this view's geometry final when I
registered a rect against it" problem: `NSTableViewDelegate.tableView(_:
toolTipFor:rect:tableColumn:row:mouseLocation:)`, called by AppKit
on-demand at actual hover time with an already-correct, live
`mouseLocation` - no pre-registered geometry to get stale or wrong.

- `ConcordanceViewController` now sets `tableView.delegate = self` and
  conforms to `NSTableViewDelegate`, implementing that one method: resolve
  `row`/`tableColumn` to a `ConcordanceRow` and segment (left/kwic/right),
  rebuild that segment's `KWICFormatter.displayLine(...)` (the same call
  `makeCell` already makes - cheap, a handful of tokens, no caching
  needed), then call a new `KWICCellView.tokenTooltip(for:alignment:
  style:labelWidth:at:)` with `mouseLocation.x` (adjusted for the label's
  4pt inset from the cell's edge - `KWICCellView.labelInset`) to find which
  token, if any, covers that position. Narrows the delegate's `rect`
  out-parameter to just the matched token's own span, so moving the mouse
  to an adjacent token triggers a fresh delegate call (and fresh tooltip)
  instead of the first token's text persisting across the whole cell.
- `KWICCellView` lost the `addToolTip`/`layout()`/`pendingTooltips` state
  and the informal `stringForToolTip` method entirely - `configure` is
  back to being a pure "render this" call with no tooltip side effects,
  and the token-hit-testing math (`tokenTooltip`, plus the underlying
  `width(of:style:)` measurement) is now a `static` function with no
  instance state, callable from `ConcordanceViewController` without a live
  cell view at all.
- Documented uncertainty, same as last round: **not independently
  confirmed working** (no interactive AppKit access this session) - this
  is the standard, Apple-documented mechanism for exactly this scenario
  (per-cell tooltip content in a table view), and computing fresh from a
  live mouse position removes an entire category of theory for why the
  previous attempt failed, but it hasn't been seen to actually work yet
  either. If this **still** doesn't show anything on the next test, that
  would point at something more fundamental (e.g. `tableView.delegate`
  assignment itself not taking effect, or a possibility not yet
  considered) rather than a geometry-timing detail - worth explicitly
  distinguishing "shows the wrong thing" from "shows literally nothing"
  in that report, since they'd point in very different directions.

Verified: `xcodebuild -scheme Corpora build`/`test` (via `BuildProject`/
`RunAllTests`) → **BUILD SUCCEEDED**, 22/22 `CorporaTests` passing
(unaffected - `KWICFormatter`'s logic didn't change, only the AppKit-side
consumer of it). Not yet manually click-tested.

**2026-09-07, manual testing (fifth round) - hover confirmed working; the
`NSTableViewDelegate` mechanism confirmed dead via a diagnostic log,
replaced with manual `NSTrackingArea`-based tracking, which is what
actually shipped:**

- A diagnostic `NSLog` placed at the very top of `tableView(_:toolTipFor:
  rect:tableColumn:row:mouseLocation:)` (before any of its own logic)
  **never printed**, even while deliberately hovering over cells with
  tooltip content configured - conclusively confirming that delegate
  method never fires for this view-based table, contrary to what its
  documentation implies. Removed it entirely (`ConcordanceViewController`'s
  `NSTableViewDelegate` conformance and `tableView.delegate = self`) rather
  than leave dead code behind.
- Replaced with plain `NSView` mouse tracking, which has no NSTableView-
  specific behavior to second-guess: `KWICCellView` now overrides
  `updateTrackingAreas()` (registering one `NSTrackingArea` with
  `.inVisibleRect` so it auto-tracks the view's current bounds through
  later resizes) and `mouseMoved`/`mouseEntered`/`mouseExited`, calling a
  new `updateToolTip(for:)` on each that converts the event's window
  location into label-relative coordinates and calls the same
  `tokenTooltip(for:alignment:style:labelWidth:at:)` hit-testing function
  from the (removed) delegate attempt, dynamically setting `self.toolTip`.
  `configure(displayLine:alignment:style:)` now stashes `displayLine`/
  `alignment`/`style` as instance state for these callbacks to read.
- A second diagnostic (`NSLog` inside `updateToolTip(for:)`, logging the
  computed point/match on every mouse event) confirmed the tracking
  callbacks fire correctly *and* the hit-testing math was already 100%
  correct - real log output showed e.g. `match=lemma: move, tag: VBG` and
  `match=tag: NN` exactly matching the actual hovered token - but the
  tooltip still didn't visibly appear. At the user's suggestion, added
  real (non-diagnostic) `.toolTip` strings to the toolbar buttons
  (History, Sort, Filter, Shuffle, Sample, Context, Attributes,
  Collocations, Frequencies, Operations) as a control test: if plain
  static tooltips on ordinary buttons also failed to appear, the issue
  would be app/window-wide, not KWIC-specific.
- **Root cause, finally**: not a code bug at all. The tracking area uses
  `.activeInKeyWindow` (the standard option for tooltip-style tracking,
  intentionally scoped to only the active window/app). A fresh Cmd+R
  launch from Xcode's debugger left the app appearing frontmost and
  accepting clicks/keyboard input normally, but genuinely *not* activated
  from the window server's own perspective - critically, the user found
  that clicking directly inside the window (even selecting a KWIC line)
  did **not** fix it, but a real Cmd-Tab away to Xcode and back did. That
  distinguishes "window has key status" (which clicking inside already
  grants) from "app is truly active" (which apparently clicking inside a
  debug-launched app's own window doesn't reliably grant) - pointing
  squarely at the app's own launch sequence never calling
  `NSApp.activate(_:)`, not at anything tracking-area/AppKit-internals
  related. Confirmed: `AppDelegate.applicationDidFinishLaunching` never
  called it at all (the only existing call site was `showSettings(_:)`,
  an unrelated menu action). Added `NSApp.activate(ignoringOtherApps:
  true)` to `applicationDidFinishLaunching` - the standard fix for exactly
  this class of debug-launch quirk. Both diagnostic `NSLog` calls removed
  once the underlying tracking/hit-testing logic was confirmed correct;
  the toolbar button tooltips were kept (genuinely useful, not just
  diagnostic) with real explanatory text.
- **Unresolved, cosmetic, separately tracked**: the "Invalid attempt to
  open a new transaction during CA commit" warning when clicking Apply in
  the Attributes popover is still reproducible even after disabling the
  table's reload animation for that path (`onResultsChanged?(false)`),
  ruling out that specific theory. Doesn't block or corrupt anything
  observable (hover, styling, and the popover itself all work correctly
  despite it) - left as a known, harmless-so-far warning rather than
  chasing it further without a concrete functional symptom attached to it.

Verified: `cd ManateeKit && swift test` → 40/40 passing (unaffected);
`xcodebuild -scheme Corpora build`/`test` (via `BuildProject`/
`RunAllTests`) → **BUILD SUCCEEDED**, 22/22 `CorporaTests` passing.
**Manually confirmed working by the user** (before the `NSApp.activate`
fix, via a Cmd-Tab workaround): per-token hover tooltips (distinct text
per token, e.g. lemma+tag), toolbar button tooltips, and (from earlier in
this same round) inline attribute styling in grey.

**2026-09-07, final round - `NSApp.activate` did not fix it either;
narrowed further and closed as a known, accepted, non-blocking issue:**

- User confirmed `NSApp.activate(ignoringOtherApps: true)` at launch made
  no difference - hover/tooltips still required one app-switch away and
  back, every time, regardless of activation call.
- Switched the tracking area from `.activeInKeyWindow` to `.activeAlways`
  (which shouldn't depend on window/app active-state detection *at all*) -
  still no difference. This was the point where the "it's an activation-
  state detection problem in my tracking area" theory should have been
  either confirmed or killed outright; it was killed.
- Used `GetConsoleOutput` (an xcode-tools MCP capability this session had
  been underusing - see below) to confirm no crash and nothing unusual in
  the launch session's console beyond the same benign system-service
  noise every launch already showed.
- Launched the actual built `.app` directly via `open` (bypassing Xcode's
  Run button/debugger-attach path entirely, i.e. the same launch path a
  real double-click would take) - **still the same behavior**. This ruled
  out "Xcode debug-launch quirk" as the cause.
- User confirmed tooltips work normally in *other* apps on the same
  machine/OS - ruling out a blanket macOS-27-beta tooltip regression.
- Checked `Info.plist` (no `LSUIElement`/background-only keys) and
  `main.swift` (`app.setActivationPolicy(.regular)` already explicit,
  correctly placed before `app.run()`) - both look correct; neither
  explains the symptom.
- At the user's request, reverted the tooltip *mechanism* itself back to
  the very first working approach (`self.toolTip`/`label.toolTip` set
  once in `configure()`, whole-line text, no `NSTrackingArea` at all) as
  a final isolation test - **exact same behavior**. This conclusively
  rules out the tooltip *mechanism* (delegate vs. tracking-area vs. plain
  static property) as the variable; whatever this is, it's independent of
  how the tooltip is registered. Reverted back to the per-token
  `NSTrackingArea` version afterward (strictly better UX once the
  underlying quirk resolves itself, and the whole-line revert bought
  nothing).
- **Conclusion, accepted by the user as non-blocking**: some one-time,
  per-launch condition - most likely a genuine macOS 27 beta AppKit/window-
  server quirk specific to this app's window/view configuration in some
  way not yet identified - prevents the tooltip *display* mechanism from
  activating until a real, full application deactivate/reactivate cycle
  happens once (Cmd-Tab away and back, or equivalent). After that single
  event, tooltips (both KWIC hover and the static toolbar-button ones)
  work correctly and reliably for the remainder of the session. Every
  other aspect of the feature - hit-testing accuracy, per-token text
  correctness, inline styling, row-overlap fix - is independently
  confirmed correct. Logged here in full rather than fixed, since further
  diagnosis would need tooling this session doesn't have (Instruments,
  or a non-beta macOS to test against for comparison) - not chased
  further given the low severity (one manual workaround, once per launch)
  relative to the time already invested.
- **Process note**: this session initially told the user it had no way to
  read the app's live console output, which was wrong - `GetConsoleOutput`
  (part of the same xcode-tools MCP surface already used for `BuildProject`/
  `RunAllTests`) works and should have been used from the start of this
  investigation instead of asking the user to manually copy-paste console
  text repeatedly. Corrected once identified; worth remembering for future
  sessions working in this same environment.

Verified: `xcodebuild -scheme Corpora build`/`test` (via `BuildProject`/
`RunAllTests`) → **BUILD SUCCEEDED**, 22/22 `CorporaTests` passing (the
mechanism reverts and re-reverts were pure `KWICCellView` internals with
no change to `KWICFormatter`'s already-tested logic).

### 5.4 — Document/structural info (engine + AppKit UI done)

Shows a hit's enclosing structural attributes (e.g. `doc.author`,
`doc.year`) via a "Document Info…" row context-menu item - the piece
explicitly flagged as missing during Phase 5.3's scoping: `Corpus.info()`
only ever exposed registry-level structure/attribute *names*, never a
per-match lookup.

**Engine/bridge**: found the exact API needed by reading manatee-open's own
sort/frequency-criteria code (`conccrit.cc`'s `crit_struct_nr`), which
led to `corp/struct.cc`'s `StructPosAttr::pos2str(Position pos)` - it
*already* resolves "which `<doc>` instance contains this token position"
internally (via `ranges::num_at_pos`) and returns that instance's
attribute value directly. No manual range-search needed on our side at
all - just call `Corpus::get_attr("doc.author")` (the plain, default
`struct_attr=false` overload, which is what routes through the
position-indexed `StructPosAttr` wrapper rather than the structure's own
instance-indexed raw attribute) and `.pos2str(position)`.

- `mtcbridge.h`/`.cc`: two new functions. `mtc_kwic_get_pos(MTCKwic*)`
  exposes the current KWIC line's corpus-wide match position (previously
  computed internally by `KWICLines` but never exposed - the position
  itself, not any text at it). `mtc_corpus_get_struct_attr(MTCCorpus*,
  position, "struct.attr", error)` wraps the `pos2str` call above,
  operating directly on the corpus handle - no open `MTCKwic`/
  `MTCConcordance` needed, so a lookup can happen long after the query
  that produced the position ran.
- `ManateeKit.swift`: `KWICLine` gained `position: Int` (every line
  already flows through one construction site in `LiveConcordance.
  kwicLines`, so this was a single-call-site change); `Corpus` gained
  `structuralAttributeValue(at:attribute:) throws -> String`.
- New tests (`CorpusInfoTests.swift`, alongside the existing registry-only
  `info()` test for contrast): queries for "fox" (only in `<doc id="1">`)
  and "cat" (only in `<doc id="2">`) in the fixture corpus, confirms
  `structuralAttributeValue` returns the correct enclosing doc's `id` for
  each - a real per-match assertion, not just registry metadata. Both
  passed on the first attempt once written, confirming the `pos2str`
  understanding was correct. Also confirms an unknown structural attribute
  name throws.

**AppKit UI**: `ConcordanceDocument` gained `queryCorpus` (kept alongside
the existing `liveConcordance`, same "survive past a single replay" reasoning) and
`structuralInfo(at rowID:) async throws -> [(structure:attribute:value:)]`
- loops every attribute of every structure `queryCorpus.info()` declares,
skipping any that come back empty for this particular hit (not every hit
is enclosed by every structure - e.g. a `<p>` that only wraps some
documents). `ConcordanceViewController` adds "Document Info…" to the
existing row right-click menu (alongside "Filter to Selection"/"Copy"),
showing the results as a plain `NSAlert` - proportionate to showing a
handful of key/value pairs for one row, not a sortable/scrollable result
set like Collocations/Frequencies get their own dedicated windows for.

Verified: `cd ManateeKit && swift test` → 42/42 passing (2 new
`CorpusInfoTests`); `xcodebuild -scheme Corpora build`/`test` (via
`BuildProject`/`RunAllTests`) → **BUILD SUCCEEDED**, 22/22 `CorporaTests`
passing (unaffected - no AppKit-layer tests exist for this feature, since
it's a one-shot alert, not logic worth isolating the way `KWICFormatter`
was). Not yet manually click-tested - next step: right-click a KWIC line
in a real corpus with structural attributes (e.g. the dev corpus's
`doc.author`/`doc.genre`/`doc.year`) and confirm "Document Info…" shows
correct, real values.

### 5.5 — Export concordance (AppKit UI done)

Exports the concordance table's visible columns (Group, Left, Match,
Right) to a CSV or TSV file - the last item on the Phase 5 roadmap. No
engine/bridge work needed: everything required (`ConcordanceRow`/
`KWICLine`) already exists on the AppKit side, so this is pure formatting
+ panel plumbing.

- `Documents/ConcordanceExporter.swift` (new): AppKit-free
  `ConcordanceExporter.export(rows:format:inlineAttributes:) -> String`,
  mirroring `KWICFormatter`'s precedent of keeping formatting logic
  separate from view/panel code so it's unit-testable without a live
  corpus or window. Exports exactly the rows given (whatever sort/filter/
  sample/line-groups are currently applied) rather than re-querying
  anything. CSV quotes fields containing commas/quotes/newlines and
  doubles embedded quotes (RFC 4180); TSV has no standard escaping
  convention, so embedded tabs/newlines are replaced with spaces instead.
  CRLF line endings.
- `inlineAttributes` (default `[]`), when non-empty, appends each listed
  attribute's value in brackets after its own word - e.g. `fox[NN]` -
  rather than one combined suffix per cell, since Left/Match/Right can
  each hold many words and a plain-text cell has no separate column/color
  to hang a secondary attribute off of the way the on-screen KWIC display
  does. Considered and dropped: an Excel (.xlsx) export with the on-screen
  coloured-inline-attribute styling. Excel's format *does* support
  per-run-formatted "rich text" within a single cell (`<r>`/`<rPr>` runs
  in a shared string - the same mechanism Excel's own UI uses for
  bold-part-of-a-cell), but the Swift library initially found for this
  (`XLKit`) only exposes whole-cell formatting; the one that wraps a C
  library exposing real rich-string runs (`xlsxwriter.swift`, over
  `libxlsxwriter`) requires vendoring a C library rather than a plain SPM
  checkout. Not worth the dependency weight without a concrete use case
  requiring an actual `.xlsx` file - the brackets-in-CSV approach above
  covers the same information losslessly.
- `Controllers/ConcordanceViewController.swift`: new `exportConcordance(_:)`
  action - an `NSSavePanel` (`.commaSeparatedText`/`.plainText` content
  types, default filename from `document.corpusName`) presented as a sheet
  on the window, with a small accessory view (`ExportAccessoryView`, one
  checkbox: "Include Inline Attributes", defaulted to whatever's currently
  shown inline on-screen). Format is chosen from the saved file's
  extension (`.csv` → comma-separated, anything else → tab-separated).
  Also new: `printConcordance(_:)`, handing `tableView` to a plain
  `NSPrintOperation` - the standard macOS print panel already offers
  "Save as PDF", so this covers the requested PDF export too without a
  second, bespoke PDF-rendering code path. The printed/PDF'd table alone
  omitted the query and hit-count/corpus-size status line shown live above
  it on-screen (`queryField`/`statusLabel`, siblings of `tableView`, not
  reachable by printing `tableView` in isolation) - rather than reparent
  the live view hierarchy for the duration of a print job,
  `SortableTableView` gained a `printHeaderLines: [String]` property drawn
  via `NSView.drawPageBorder(with:)` (an AppKit pagination hook called
  once per printed page specifically for header/footer/border marks,
  outside the normal content-drawing path - never invoked during ordinary
  on-screen display), so `printConcordance(_:)` sets
  `tableView.printHeaderLines` right before printing and `printInfo
  .topMargin` is widened to leave room for it. Styled to match the live
  window rather than plain text (found lacking on first manual test,
  2026-09-07): `printHeaderLines` is `[NSAttributedString]`, not
  `[String]`. The query line reuses `CQLQueryField`'s own CQL syntax
  coloring - factored out of its private `recolor()` into a new `static
  func syntaxColoredAttributedString(for:font:)` so both the live editor
  and this non-editable print rendering produce identical colors
  (quoted values red, `within`/`containing`/etc. purple, operators
  orange, `<tag>`s teal) without duplicating the regex table; the status
  line matches `statusLabel`'s own font/`.secondaryLabelColor`.
- `AppDelegate.swift`: "Export Concordance…" (⌘E) and "Print…" (⌘P) added
  to the File menu, target `nil` so both resolve via the responder chain -
  only `ConcordanceViewController` implements either selector, so AppKit's
  standard menu validation disables both whenever no concordance window is
  key, with no manual enablement logic needed.
- Tests (`ConcordanceExporterTests.swift`, 10 tests): header + column
  order, CSV comma-quoting, CSV embedded-quote-doubling, TSV tab/newline
  replacement, empty-rows-is-just-the-header, multiple rows each on their
  own line, plain words unchanged when `inlineAttributes` is omitted,
  bracketed values appended per word, multiple attribute values joined
  with `/` within one bracket, a token missing the requested attribute
  left unbracketed.

Verified: `xcodebuild -scheme Corpora build`/`test` (via
`BuildProject(buildForTesting: true)`/`RunAllTests`) → **BUILD SUCCEEDED**,
32/32 `CorporaTests` passing (10 in `ConcordanceExporterTests`). Not yet
manually click-tested - next steps: run a query with an inline attribute
configured, choose File → Export Concordance…, toggle "Include Inline
Attributes" both ways, save as both `.csv` and `.txt`, and confirm both
open correctly with the right columns/escaping/brackets; separately,
File → Print… on a multi-page concordance and confirm the query/status
header appears once per page above the table, the table itself paginates
sensibly, and "Save as PDF" from the print panel produces a usable PDF.

**Considered and dropped: Excel export.** Excel's `.xlsx` format *does*
support per-run-formatted "rich text" within a single cell (`<r>`/`<rPr>`
runs in a shared string - the same mechanism Excel's own UI uses for
bold-part-of-a-cell) - so replicating the on-screen coloured-inline-
attribute look wasn't ruled out by the file format, only by tooling: the
Swift library first found for this (`XLKit`) only exposes whole-cell
formatting, and the one that wraps a C library exposing real rich-string
runs (`xlsxwriter.swift`, over `libxlsxwriter`) requires vendoring a C
library rather than a plain SPM checkout. Not worth the dependency weight
without a concrete use case requiring an actual `.xlsx` file - the
brackets-in-CSV approach above covers the same information losslessly.

**Investigated, inconclusive, not chased further: a one-off 0-hit result
on a query's first run (2026-09-07).** Reported once:
`[lemma="být"][word="k"]` against `syn2025` returned "0 hits"
immediately; editing the query to `[word="je"][word="k"]` and running it
got real results; editing it back to the exact original text and running
it again also got real results. Investigated and ruled out as root
causes: (1) any query-result caching in `manatee-open` or `ManateeKit` -
`mtc_query()` always does `eval_cqpquery()` → `filter_query()` → `new
Concordance(...)` fresh, every call; (2) a separate/lazy-loaded code path
for secondary attributes like `lemma` vs. the primary `word` attribute -
both compile through the identical `getAttr(name)->regexp2poss(...)`
call; (3) Unicode normalization drift in `QueryHistoryStore` - the
persisted query string was confirmed to already be canonical NFC; (4)
stale index files from a just-finished recompile - the user confirmed
`syn2025` had been queried successfully many times before this happened.
The user's working theory was that `syn2025` itself had been compiled by
an earlier, since-fixed buggy import path (see Phase 4's "duplicate-
`word`-attribute crash"/stale-directory bugs) - but a follow-up repro of
the *exact same query* on 2026-09-07 succeeded on the first try, with no
code changes in between, so that's not confirmed either. Genuinely
inconclusive: no reproduction recipe, no live console capture from the
one actual failure. Per the user ("we will chase it if it appears
again"): not investigated further unless it recurs, at which point
capture Xcode console output (`GetConsoleOutput`) during the failing run
itself, since that's the one class of evidence not yet gathered.

## Phase 6 — Concordance UX, round 2 (KonText comparison) (not started)

Phase 5 closed out the user's first KonText-comparison pass. This is
round 2: another functional comparison against KonText (specifically
informed by `korpus.cz`, a live KonText deployment) turned up 5 more
gaps, plus two more raised mid-planning (`doc.title` always shown in
KWIC; styling settings for fonts/colors). Research this session (Explore
agents + `DocumentationSearch`/grep) turned up 3 more real gaps not on
the user's list, which the user asked to include too. Every item below
is either explicitly confirmed by the user via `AskUserQuestion` or a
directly-requested addition - an agreed 11-item roadmap, not speculative
scope.

**Order** (user-confirmed "cheapest-first, biggest/most novel last" for
the original 5, with later additions slotted in near related work):

1. KWIC-centered window resizing
2. `doc.title`-style structural attribute shown on every KWIC line
3. KWIC / Sentence view switch
4. Concordance settings tab (behavioral defaults)
5. Appearance settings: concordance styling (fonts + colors)
6. Extended context on the selected line
7. New engine primitive: attribute value enumeration (shared foundation for 8 & 9)
8. CQL attribute-name/value autocomplete
9. Text-Types-style subcorpus creation
10. Charts: Collocations/Frequency bar charts + concordance dispersion plot
11. Concordance result pagination/streaming

Each is scoped to be independently shippable/testable, matching how
Phase 5's sub-phases were built and committed one at a time.

### 6.1 — KWIC-centered window resizing (AppKit UI done)

Built directly against today's 4-column set (`group`/`left`/`kwic`/
`right`) rather than waiting on 6.2's new structural-attribute column,
per explicit user direction to start Phase 6 at its first item - 6.2's
future column just needs `resizingMask = []` (fixed) to slot in later
without disturbing this.

**Problem** (confirmed via Explore agent, `ConcordanceViewController.swift`
`setUpTableView` ~:334-382): `columnAutoresizingStyle` was
`.lastColumnOnlyAutoresizingStyle` and only the `right` column had
`.autoresizingMask` — widening the window grew only the Right column;
Left and Match(KWIC) stayed pixel-fixed, so the match visibly drifted
left as the window widened instead of staying centered.

**Fix**: `left` and `right` both now carry `[.userResizingMask,
.autoresizingMask]` (equal starting widths, 270/270 - manual drag-resize
still works on both, same as before, in addition to auto-grow), `kwic`
stays `.userResizingMask` only (no auto-grow), `group` stays fixed;
`tableView.columnAutoresizingStyle` changed to
`.uniformColumnAutoresizingStyle` — this splits added/removed width
across all `.autoresizingMask` columns, which with equal starting widths
keeps Left and Right growing together and the Match column visually
centered. Config-only change, no new code.

Verified: `BuildProject(buildForTesting: true)` → **BUILD SUCCEEDED**;
`RunAllTests` → 32/32 `CorporaTests` passing (unaffected - no test
exercises column-resize behavior). Not yet manually click-tested - next
step: widen/narrow the window in Xcode and confirm Left/Right grow
symmetrically together while Match stays visually centered.

**Verify**: `BuildProject` + manual resize test in Xcode (widen/narrow the
window, confirm Left/Right grow symmetrically and Match stays centered).

### 6.2 — `doc.title`-style structural attribute on every KWIC line (AppKit UI done)

KonText (per `korpus.cz`) always shows a structural attribute (typically
`doc.title`) on every concordance line — document identity at a glance,
not just on click like the existing "Document Info…" popup.

**Implemented**:
- `ConcordanceDocument` gained `structuralAttributeToShow: String?`
  (persisted the same nil-for-back-compat way as `inlineAttributes`/
  `tooltipAttributes`) and `setStructuralAttributeDisplay(_:)` calling
  `refetchDisplay()`, same pattern as `setAttributeDisplay`. **Revised
  after first manual test**: initially built as a checklist
  (`structuralAttributesToShow: [String]`), but since there's only ever
  one "Doc" column, checking a second box silently did nothing - the
  user caught this and asked for the model itself to be single-valued,
  not just the UI, citing HIG's guidance on mutually-exclusive choices
  (and specifically radio buttons, `NSButton.ButtonType.radio`, over a
  pop-up, per the older HIG's fuller treatment of when to prefer each).
  Simplified end-to-end to `String?` rather than leaving a `[String]`
  that only ever honored its first element.
- `ConcordanceRow` gained `structuralAttributeValue: String?` (via an
  explicit init with a `nil` default, not a plain stored-property default
  - the synthesized memberwise init didn't pick the default up for an
  explicit-argument call the way expected, so a real `init` was simpler
  than chasing why), populated in `buildRows` by calling the *existing*
  `Corpus.structuralAttributeValue(at:attribute:)` (built in Phase 5.4 for
  "Document Info…") - no new engine API needed, just a new eager call
  site for an existing one.
  - **Performance**: `buildRows` now fans *every* row's `linegroup(at:)`
    lookup and structural-attribute lookup out concurrently via a
    `withTaskGroup`, rather than one `await` per row in sequence (which is
    what it did before this change, for `linegroup` alone) - a real,
    incidental improvement to existing behavior, not just new-feature
    scaffolding. Revisit if still slow once 6.11 (pagination) caps how
    many rows are ever materialized at once.
- New fixed-width structural-attribute table column, between `group` and
  `left` (`resizingMask = .userResizingMask`, no `.autoresizingMask` -
  stays out of 6.1's Left/Right symmetric-growth centering), hidden
  entirely (`NSTableColumn.isHidden`) whenever `structuralAttributeToShow`
  is nil rather than shown-but-blank. New `KWICCellView.configureStructuralInfo(_:)`
  - a small secondary-style label, same spirit as the existing
  `configureGroup` badge, not routed through `KWICFormatter`'s per-token
  segment machinery since the value is constant for the whole line.
  Color is `.secondaryLabelColor` for now; 6.5 will make it a real
  setting. **Revised after manual testing**: the column header was
  originally a fixed "Doc" title regardless of which attribute was
  chosen - the user asked for it to reflect the actual attribute (e.g.
  "doc.title", "doc.author") instead, so `updateStructuralColumn()` (was
  `updateStructuralColumnVisibility()`) now sets `column.title =
  document.structuralAttributeToShow ?? "Doc"` alongside `isHidden`, and
  `setUpTableView` seeds the same title at creation time.
- `AttributeDisplayPopoverController` gained a second section,
  "Structural" - a radio-button group (`NSButton(radioButtonWithTitle:)`),
  one per fully-qualified name (e.g. "doc.title") plus "None", sourced
  from `Corpus.info().structures` rather than `Corpus.info().attributes`.
  `onApply`'s signature grew a third `String?` parameter for the
  selected structural attribute. **Revised after a second manual test**
  (screenshot showed more than one button stayable-checked at once):
  AppKit's automatic same-superview radio grouping didn't actually kick
  in with `target: nil, action: nil` (grouping most likely requires a
  shared, non-nil target/action to recognize siblings as one group) - so
  exclusivity is now managed explicitly, in a new
  `structuralRadioTapped(_:)` action shared by every button in the
  group, which turns every other button in `structuralRadioButtons` off
  whenever one is tapped.

**Key files**: `ConcordanceDocument.swift`, `ConcordanceViewController.swift`
(new "Doc" column in `setUpTableView`/`makeCell`, `updateStructuralColumnVisibility`),
`AttributeDisplayPopoverController.swift`, `KWICCellView.swift`.

**Not added**: an automated test for the row-building wiring itself - the
underlying engine call (`structuralAttributeValue`) already has real
coverage from Phase 5.4's `CorpusInfoTests`, and this target
(`CorporaTests`) has no existing precedent for spinning up a real
compiled fixture corpus of its own (unlike `ManateeKitTests`'
`TestCorpusFixture`) - same "one-shot, not logic worth isolating"
reasoning Phase 5.4 used for `structuralInfo(at:)`'s own AppKit wiring.

Verified: `BuildProject(buildForTesting: true)` → **BUILD SUCCEEDED**;
`RunAllTests` → 32/32 `CorporaTests` passing (unaffected). Not yet
manually click-tested - next step: enable "doc.title" (or `.author`) in
the Attributes popover's new Structural section on a corpus that has one,
confirm the "Doc" column appears with the right value per row and stays
hidden when nothing's checked.

### 6.3 — KWIC / Sentence view switch (done)

**Confirmed free ride** (Explore agent, `manatee-open/concord/concctx.cc`
:174-280): `KWICLines`' left/right context parameters are already
free-form `const char*` strings, not integers, all the way from Swift
(`LiveConcordance.kwicLines(leftContext:rightContext:...)` →
`mtcbridge.cc:195`'s `new KWICLines(...)`) — and manatee-open already
parses Bonito/Sketch-Engine-style context specs including `"-1:s"`/`"1:s"`
("expand to the enclosing `<s>` boundary"), with graceful fallback to
±3 tokens if the structure doesn't exist or isn't found at that position.
**Zero new bridge/engine code required** beyond one config literal.

**Implemented**:
- New `ConcordanceViewMode` enum (`.kwic`/`.sentence`),
  `ConcordanceDocument.viewMode` (persisted, defaults to `.kwic` for
  back-compat), and `setViewMode(_:)`. `leftContext`/`rightContext`
  themselves are **never touched** by view-mode switching - a new
  private `effectiveLeftContext`/`effectiveRightContext` pair (used only
  at the two `live.kwicLines(...)` call sites in `replay()`/
  `refetchDisplay()`) resolves to `"-1:s"`/`"1:s"` in `.sentence` mode or
  the real numeric strings otherwise. This means switching to Sentence
  view and back to KWIC needs no separate "remembered width" bookkeeping
  at all - `setContext`'s numeric value was simply never overwritten in
  the first place.
- Toolbar gained a "KWIC | Sentence" `NSSegmentedControl` (new
  `ItemID.viewMode`, between Sample and Context), wired to
  `ConcordanceViewController.viewModeChanged(_:)`. The existing numeric
  Context button is disabled while in Sentence mode (doesn't apply, per
  the plan) - `ConcordanceWindowController.updateToolbarState` gained a
  `viewMode` parameter alongside `hasLineGroups` for this.
- `ConcordanceViewController` gained a small `var viewMode:
  ConcordanceViewMode { document.viewMode }` accessor - `document`
  itself stays `private`, but `ConcordanceWindowController` needs the
  current mode at toolbar-item-creation time (segmented control's
  initial selection, Context button's initial enabled state), before any
  `refresh()`/`updateToolbarState` call has happened yet.
- `mtcbridge.cc:195`'s hardcoded `maxctx=100` (would have truncated any
  sentence longer than 100 tokens) raised to 2000 - generous for any
  realistic `<s>`, still bounding a pathological/mistagged structure.
- Table structure is unchanged (still Left/Match/Right columns) - a
  sentence's pre-match/post-match text just naturally fills Left/Right
  instead of a fixed token count. Existing single-line truncation
  (`KWICCellView`'s `maximumNumberOfLines = 1`, from the Phase 5.3
  row-overlap bug fix) stays as-is; 6.6's Extended Context popover is the
  escape hatch for seeing a truncated line in full.

**Key files**: `ConcordanceDocument.swift`, `ConcordanceWindowController.swift`,
`ConcordanceViewController.swift`, `ManateeKit/Sources/CManatee/mtcbridge.cc`.

New test, `LiveConcordanceTests.testKwicLinesWithSentenceAlignedContextStopsAtSentenceBoundary`:
queries `"jumps"` (the last word of its sentence in the fixture corpus)
with `rightContext: "1:s"` and asserts the right context is empty rather
than spilling into the next sentence/doc the way a numeric width would;
queries `"the lazy"` (the next sentence's opening bigram) with
`leftContext: "-1:s"` and asserts the left context doesn't reach back
into the previous sentence's "jumps" - a real end-to-end check that the
context-spec string does what's claimed, not just that it passes
through unchanged.

Verified: `cd ManateeKit && swift test` → **43/43 passing** (1 new);
`BuildProject(buildForTesting: true)` → **BUILD SUCCEEDED**;
`RunAllTests` → 32/32 `CorporaTests` passing (unaffected). Not yet
manually click-tested - next step: toggle the KWIC/Sentence switch on a
corpus with real multi-token sentences and confirm each line's context
stops at sentence boundaries, and that the Context button visibly
disables/re-enables with the switch.

### 6.4 — Concordance settings tab (behavioral defaults) (done)

New `Settings/ConcordanceSettingsViewController.swift`, registered as a
4th case in `SettingsWindowController`'s `Pane` enum (`General`/
`Appearance`/`Corpora` before - adding a case was the entire registration
step, exactly as expected). Holds **global defaults for brand-new
concordance documents** (not per-document overrides, which stay on the
toolbar popovers) - `AppSettings.minimumFreeMemoryAfterResidency`'s
getter/setter shape was the precedent followed for each new property.

**New `AppSettings` properties** (all plain `UserDefaults`-backed,
following the existing `Key` enum + computed-property pattern):
- `defaultLeftContext: Int` / `defaultRightContext: Int` (default 10 each)
- `defaultViewMode: ConcordanceViewMode` (default `.kwic` - stored as the
  enum's own `rawValue` string, not a separate hand-rolled "kwic"/
  "sentence" string as originally sketched, since the real enum from 6.3
  already exists and round-trips through `RawRepresentable` for free)
- `defaultExtendedContextTokens: Int` (default 50 - feeds 6.6)

`ConcordanceDocument`'s hardcoded property-declaration defaults
(`leftContext = "-10"`, `rightContext = "10"`, `viewMode: ConcordanceViewMode = .kwic`)
now read `AppSettings.shared` at declaration time instead (e.g.
`var leftContext = "-\(AppSettings.shared.defaultLeftContext)"`) - this
runs once per `ConcordanceDocument` instance at creation, correct for
both the brand-new-document path (nothing else was setting these) and
the reopen-a-saved-document path (`read(from:)` immediately overwrites
them anyway).

New pane's UI: default context width (two small integer fields, same
plain-`NSTextField` style as the existing Context popover), the default
KWIC/Sentence view (an `NSSegmentedControl`, same control as the
concordance window's own toolbar switch), and the default extended-
context token count (feeds 6.6, not yet built, but grouped here since
it's the same category of setting) - saved on end-of-editing
(`NSTextFieldDelegate.controlTextDidEndEditing`) for the text fields,
immediately on click for the segmented control.

**Key files**: new `ConcordanceSettingsViewController.swift`,
`SettingsWindowController.swift`, `AppSettings.swift`,
`ConcordanceDocument.swift`.

Verified: `xcodegen generate` (picked up the new file) then
`BuildProject(buildForTesting: true)` → **BUILD SUCCEEDED**; `RunAllTests`
→ 32/32 `CorporaTests` passing (unaffected - no test exercises Settings
UI). Not yet manually click-tested - next step: change each default in
the new Concordance settings pane, confirm the *next* new concordance
window picks them up while an already-open one is unaffected.

**Follow-up after manual testing**: the user liked the Concordance pane's
own toolbar icon and asked for the concordance window's "KWIC | Sentence"
toolbar switch (6.3) to use icons matching it, rather than text labels -
`ConcordanceWindowController`'s segmented control now uses
`"text.aligncenter"` (centered lines - reads as "the match centered in a
fixed window") for KWIC and `"text.alignleft"` (left-aligned lines, i.e.
a normal paragraph) for Sentence, the latter matching
`SettingsWindowController.Pane.concordance`'s own icon. The Settings
pane's own segmented control was deliberately left as text labels - the
ask was specifically about the toolbar, and text reads more clearly in a
persistent settings panel than an icon-only one would.

**Second follow-up**: the icon-only segmented control's single whole-control
`.toolTip` showed the same combined "KWIC: ... Sentence: ..." text
regardless of which icon was actually hovered - confusing with two
distinct meanings now hidden behind icons rather than self-explanatory
text labels. `NSSegmentedCell.setToolTip(_:forSegment:)` exists but
Apple's own docs say plainly "Tooltips are currently not displayed," so
that's not usable. New private `PerSegmentToolTipSegmentedControl`
(`ConcordanceWindowController.swift`) tracks the mouse
(`NSTrackingArea`+`mouseMoved`) and swaps the control's own `toolTip` for
whichever segment it's over - the same technique already used for
per-token KWIC tooltips (`KWICCellView`, Phase 5.3), which had an
unresolved, never-root-caused "needs one app-switch after launch before
tooltips appear" quirk logged as non-blocking. Applying the same
mechanism here carries some risk of the same quirk recurring, but the
suspected contributing factor there (a table *cell* view being
constantly recreated/reused by the diffable data source) doesn't apply
to a toolbar item's view, which is created once and kept for the
toolbar's lifetime - worth watching for during manual testing, not
assumed safe.

### 6.5 — Appearance settings: concordance styling (fonts + colors) (AppKit UI done)

Prompted directly by the user - partly closing a loop flagged back in
Phase 5.3 ("attributes are displayed... Start with grey. Later we'll
make settings panel for that or something").

**Fonts**:
- The existing `AppSettings.resultsFontName`/`resultsFontSize`
  (`AppearanceSettingsViewController`, already consumed by `KWICCellView`)
  already *is* the concordance font, already independent from the rest of
  the app's chrome. No separate general "UI font" override was added -
  that would cut against this project's own "stick to the Macintosh HIG"
  preference.
- **New**: per-script concordance fonts. `AppSettings.scriptFontOverrides:
  [String: String]` (`UnicodeScript.rawValue` → font name, e.g.
  "cyrillic" → "Helvetica"), edited via an add/remove table in the
  Appearance pane. New dependency-free `UnicodeScript.swift`
  (`Documents/`, no AppKit/engine dependency - pure rendering concern):
  code-point-range classification covering Latin/Cyrillic/Greek/Hebrew/
  Arabic/CJK, generic `.other` bucket, with `dominant(in:)` scanning a
  token's scalars for the first one that classifies (so e.g. `"123fox"`
  still resolves to `.latin`, not `.other`, from the digits alone).
  `KWICCellView`'s `wordFont(for:baseFont:style:)` applies the override
  (if any) to `.word`-kind segments only - not `.secondaryAttribute`
  segments (POS tags etc. are conventionally Latin regardless of the
  corpus's own script, so they stay on the base font). Per-token
  granularity, not per-character, per the original plan.
- Picking a script's font reuses the exact same Font Panel flow as the
  base results font (`NSFontManager.shared.target`/`.action` swapped
  right before showing the panel) - a pull-down button lists scripts not
  yet overridden; picking one opens the panel for it.

**Colors**:
- Positional (secondary) attribute color - was hardcoded
  `.secondaryLabelColor` in `KWICCellView` - now
  `AppSettings.positionalAttributeColor` (same default), an `NSColorWell`
  in Appearance.
- Structural attribute color (6.2's "Doc" column) - same pattern, new
  `AppSettings.structuralAttributeColor`.
- Alternating row background - `tableView.usesAlternatingRowBackgroundColors`
  was hardcoded `true` - now `AppSettings.usesAlternatingRowBackground`
  (same default), a checkbox in Appearance; `ConcordanceViewController`
  re-applies it live in `settingsDidChange` (previously only
  `tableView.reloadData()` ran there, for font changes).
- **Dropped, not built**: a custom tint color for the alternating stripe
  itself. That needs custom row drawing - `NSTableView`'s own alternating
  colors aren't independently recolorable via a simple property - and no
  native Mac app actually exposes this, so it wasn't worth the
  custom-drawing complexity for a look nothing else offers either.
  CQL syntax-highlighting colors and a dedicated match/keyword highlight
  color (flagged as candidates in the original plan) were also left out
  - genuinely optional, and this sub-phase was already large enough.
- `NSColor` has no native `UserDefaults` support - new private
  `AppSettings.color(forKey:)`/`setColor(_:forKey:)` archive via
  `NSKeyedArchiver`/`Unarchiver` (`NSColor` conforms to
  `NSSecureCoding`), same shape as every other property here plus one
  encode/decode step.

**Key files**: new `Documents/UnicodeScript.swift`, `AppSettings.swift`,
`Settings/AppearanceSettingsViewController.swift` (fully reworked - font
picker plus three new sections), `KWICCellView.swift`,
`ConcordanceViewController.swift` (`setUpTableView`/`settingsDidChange`).

New tests, `UnicodeScriptTests.swift` (3): each covered script classifies
correctly from a representative word; digits/punctuation/empty/whitespace
fall back to `.other`; a token mixing leading digits with real script
text (`"123fox"`, `"123быть"`) still resolves via its first classifying
scalar rather than stopping at the digits.

Verified: `xcodegen generate` (picked up `UnicodeScript.swift`) then
`BuildProject(buildForTesting: true)` → **BUILD SUCCEEDED**; `RunAllTests`
→ 35/35 `CorporaTests` passing (3 new). Manually tested and confirmed
working (screenshot).

**Two unrelated bugs found during that same manual test, on a real
~30-attribute corpus:**

1. **`FilterSheetController`'s positive/negative radio buttons weren't
   mutually exclusive** - the exact same root cause as 6.2's structural
   radio buttons (`NSButton(radioButtonWithTitle:target: nil, action:
   nil)`, relying on AppKit's automatic same-superview grouping, which
   doesn't reliably engage with a `nil` target/action). Fixed the same
   way: explicit `radioTapped(_:)` action turning the other one off.
   Grepped for every other `radioButtonWithTitle` use in the app to
   confirm these were the only two spots with the bug.
2. **The Attributes popover had no scroll view and no height cap** - a
   corpus declaring dozens of positional *and* structural attributes (a
   real ~30-attribute corpus, confirmed via screenshot) grew the popover
   tall enough to run off the top of the screen entirely, with the
   title/header cut off and no way to scroll up to it. Fixed: the two
   attribute lists now live inside one `NSScrollView` (a `contentStack`
   documentView, height-capped at `maxScrollHeight = 320`pt via an
   explicit `scrollHeightConstraint`, computed from
   `contentStack.fittingSize.height` after each repopulation), with the
   main title and Apply/error chrome staying fixed outside it. Also (the
   user's own related idea, "think about making the structural attributes
   2 column if there are more than X"): more than `structuralColumnThreshold
   = 12` structural attributes now split into two side-by-side columns
   rather than one long list - safe now that radio exclusivity is
   managed explicitly rather than depending on every button sharing one
   literal stack view. Deliberately scoped to the structural section only
   (as asked) - the positional-attribute checklist keeps its existing
   single-column layout.

Verified (both fixes): `BuildProject(buildForTesting: true)` → **BUILD
SUCCEEDED**; `RunAllTests` → 35/35 `CorporaTests` passing (unaffected).
Not yet manually re-tested - next step: reopen the Filter sheet and
confirm exactly one of Keep/Remove stays checked; reopen the Attributes
popover on the same large corpus and confirm it now scrolls within a
fixed height instead of growing off-screen, and that the structural
section shows two columns.

### 6.6 — Extended context on the selected line (done)

KonText's "concordance detail" view - see much wider context than the
table row shows, for one specific hit.

**Implemented** (uses the position-indexed lookup pattern from Phase 5.4,
not a full requery): new bridge primitive
`mtc_corpus_positional_attr_range(corpus, fromPosition, toPosition,
attrName, error) -> char*` (space-joined tokens, clamped to
`[0, search_size())` inside the bridge rather than trusting the caller's
range) - a straightforward extension of the *already proven* "call
`PosAttr::pos2str` directly off a position, no live concordance needed"
approach `mtc_corpus_get_struct_attr` established. Wrapped in
`Corpus.positionalAttributeRange(from:to:attribute:)`.

- `ConcordanceDocument.extendedContext(at rowID:) async throws ->
  (before: String, match: String, after: String)`: given a row's
  `position` (already on `KWICLine`) and its match length
  (`kwicTokens.count`), fetches `[position - N, position + matchLen + N)`
  for `N` = 6.4's `defaultExtendedContextTokens`, then splits the
  returned space-joined string back into before/match/after by
  computing `actualTokensBefore = min(N, position)` client-side - the
  same clamp the bridge itself applies at its lower bound, needed here
  so the split point stays correct for a hit near the very start of the
  corpus without a second round-trip to ask "how much did you actually
  clamp".
- Trigger: a new "Extended Context…" row context-menu item, right next to
  the existing "Document Info…" (`ConcordanceViewController.swift`'s
  `menuNeedsUpdate`/`showDocumentInfo` is the exact precedent copied -
  same `tableView.clickedRow` pattern, single-row only, matching the
  user's "if only one selected" framing since the context menu already
  only makes sense for a single clicked row).
- Display: new `ExtendedContextWindowController.swift` - not an `NSAlert`,
  since context can be long and needs scrolling - built on
  `NSTextView.scrollableTextView()` (not a hand-assembled
  `NSScrollView`+`NSTextView` pair - already wires up wrapping/resizing
  correctly), read-only, with the match bolded and accent-colored between
  the plain-styled before/after text.
  - **Was a sheet, is now a plain non-modal window** (an
    `NSWindowController` shown through `ConcordanceViewController`'s
    existing `show(_:)`/`auxiliaryWindowControllers` disposable-window
    pattern, same as Collocations/Frequency): a sheet can only ever have
    one open per parent window, which can't support several Extended
    Contexts on screen at once. The `ExtendedContextDisplayMode` case
    keeps its `sheet` name/rawValue for UserDefaults backward
    compatibility, but the Settings UI labels it **"Window"**.
  - Each window shows which hit it belongs to -
    `ConcordanceDocument.ExtendedContextInfo` (corpus / document /
    sentence, rendered by its `headerLines`, fetched by
    `extendedContextInfo(at rowID:)`) - since once several can be open
    side by side, nothing else on screen says which window is which line.

**Follow-up - inline display mode**: the user asked for a second way to
see this - expanding the clicked row itself in place into a
word-wrapped paragraph, rather than always popping a sheet - switchable
via a new setting (6.4's Concordance pane), not a replacement.
- `ExtendedContextDisplayMode: String, Codable { case sheet; case
  inline }` (`ConcordanceDocument.swift`) + `AppSettings
  .extendedContextDisplayMode` (default `.sheet`, the original
  behavior) - a global preference, not per-document, since it's purely
  presentational. New "Extended context display: Sheet | Inline"
  segmented control in `ConcordanceSettingsViewController`.
- `showExtendedContext(_:)` now branches on the setting: `.sheet` is
  the unchanged popup above; `.inline` calls a new
  `toggleInlineExtendedContext(for:)`.
- Transient UI state on `ConcordanceViewController` (not
  `ConcordanceDocument` - doesn't survive a real replay): `expandedRowID:
  Int?`/`expandedContext: (before:match:after:)?`. Re-triggering on the
  already-expanded row collapses it; expanding a different row collapses
  whichever was open first (one expansion at a time, matching the sheet
  mode's own "if only one selected" framing). `refresh(animated: true)`
  (a real replay - sort/filter/requery, as opposed to a display-only
  `settingsDidChange`-style reload) clears the expansion, since row ids
  can be renumbered underneath it.
- **One continuous paragraph, not three columns**: the first version of
  this rendered the expanded row's before/match/after text into the
  existing Left/Match/Right cells, which still visually chopped it into
  three separate pieces - rejected by the user ("it must be an
  uninterrupted paragraph, not split into left/match/right"). Fixed by
  rendering nothing in any column cell for the expanded row
  (`makeCell` returns a blank `NSView()` for every column when
  `rowID == expandedRowID`) and instead overlaying one full-row-width
  `NSTextField(wrappingLabelWithString:)` (`ExtendedContextOverlayField`,
  a marker subclass used only to find/remove it later) directly on that
  row's `NSTableRowView`, pinned via Auto Layout to the row view's own
  leading/trailing/top/bottom anchors - so it spans the whole row
  (ignoring column boundaries entirely) and tracks the row's width
  automatically as Left/Right auto-grow on resize, no manual
  repositioning needed. `KWICCellView.extendedContextParagraph(before:
  match:after:)` builds the single `NSAttributedString` (match
  bold/accent, joined with plain spaces, one left-aligned word-wrapping
  paragraph style throughout).
- `tableView.delegate = self` is now set (previously unset -
  `SortableTableView` never used a delegate for anything) so
  `ConcordanceViewController` can implement `NSTableViewDelegate
  .tableView(_:heightOfRow:)` (sizes the expanded row to
  `KWICCellView.extendedContextHeight(for:width:)` at the table's own
  current width - shared with the overlay's own text so the row is
  always exactly as tall as what's drawn) and `.tableView(_:didAdd
  rowView:forRow:)` (the passive counterpart to the eager
  `applyExpansionChange` - reapplies the correct overlay state whenever
  AppKit hands back a row view, including a freshly-scrolled-into-view
  one or a recycled one that used to belong to a different, possibly
  still-expanded row). A `NSTableView.columnDidResizeNotification`
  observer renotes the expanded row's height after 6.1's symmetric
  Left/Right resize changes the table's overall width.
- `applyOverlay(to:row:)` is the single idempotent choke point for
  add/update/remove, called from both `applyExpansionChange` (eagerly,
  right after toggling) and `didAdd` (passively) - looked up via
  `rowView.subviews.compactMap { $0 as? ExtendedContextOverlayField
  }.first` rather than separate tagging/bookkeeping.

**Key files**: `mtcbridge.h`/`.cc`, `ManateeKit.swift`,
`ConcordanceDocument.swift`, `ExtendedContextWindowController.swift`,
`ConcordanceViewController.swift`, `KWICCellView.swift`, `AppSettings.swift`,
`ConcordanceSettingsViewController.swift`.

**Known dangling reference**: doc comments in
`ExtendedContextWindowController` and on `ExtendedContextDisplayMode` both
cite `AppSettings.allowMultipleExtendedContexts` as the reason the sheet
became a window, but **that setting does not exist** - the rationale was
written ahead of the setting, and `AppSettings.swift` has zero occurrences
of it. Multiple windows do in fact work today (the `show(_:)` pattern
retains each one), just unconditionally rather than behind a preference.
6.6a below is what makes the comments true.

New tests, `CorpusInfoTests.swift` (3): a plain in-bounds range returns
the expected space-joined words for both "word" and "lemma"; a range
request running off either end of the fixture corpus (position ± N
naturally does this for a hit near the start/end) clamps rather than
throwing or reading garbage; an unknown attribute name throws.

Verified: `cd ManateeKit && swift test` → **46/46 passing** (3 new);
`xcodegen generate` (picked up the new sheet controller) then
`BuildProject(buildForTesting: true)` → **BUILD SUCCEEDED**; `RunAllTests`
→ 35/35 `CorporaTests` passing (unaffected - no AppKit-layer test exists
for this feature, same "one-shot window, not logic worth isolating"
reasoning as 5.4's "Document Info…").

**Manually click-tested by the user 2026-09-08: works, but needs
refinements** - four of them, written up as 6.6a below. Nothing found was
a defect in what's described above; they're all changes to the *design*,
two of which deliberately revisit earlier decisions recorded here.

### 6.6a — Extended Context refinements (AppKit UI done)

All four came from the user's own click-through of 6.6. Ordered
cheapest-first, which also happens to be lowest-risk-first; items 3 and 4
were near-trivial next to 1 and 2.

**The three open questions this section originally left are settled** (all
resolved as the recommendations recorded here, confirmed by the user's
"implement it" plus the explicit reminder that item 1 is *only* an option):
1. The disclosure triangle appears **only** when
   `allowMultipleExtendedContexts` is on. With one-at-a-time expansion
   there's little to disclose and the triangle would only add a column of
   chrome, so the default stays visually identical to 6.6.
2. The overlay clears **all** leading metadata columns, not just `doc`.
   The user's report named the structural attribute column, but a
   paragraph starting at x=0 runs over a visible line-group number just as
   badly - and over the disclosure triangle it would break collapsing
   outright, which settled it.
3. Double-clicking an expanded row **collapses** it, so the gesture is a
   toggle like every other trigger.

**Item 4 - Window carries Match info, gated on the multiplicity setting.**
Mostly already built (see 6.6 above): it is already an
`NSWindowController`, already shows corpus/document/sentence via
`ExtendedContextInfo.headerLines`, and already supports several open at
once through `show(_:)`. All that's missing is the **gate**: opening a
second Extended Context should only be additive when the new setting is
on; with it off, opening one for a different row should replace the
existing window rather than stack up. Implementation is in
`ConcordanceViewController.showExtendedContext(_:)` plus
`auxiliaryWindowControllers` bookkeeping - it needs to distinguish
Extended Context windows from Collocations/Frequency ones, since only the
former are subject to the limit.

**Item 3 - Double-click a row to show Extended Context.** Currently the
only trigger is the "Extended Context…" row context-menu item (added next
to "Document Info…", see `menuNeedsUpdate`). There is **no** `doubleAction`
wiring anywhere in the project today. Set `tableView.target`/
`tableView.doubleAction` to a new selector that reuses
`showExtendedContext(_:)`'s body, keyed off `tableView.clickedRow` exactly
as the context-menu path already is. Two things to settle:
- Double-clicking an *already expanded* inline row should collapse it, so
  the gesture stays a toggle and matches the context-menu behavior.
- `SortableTableView` handles click-to-sort on *headers*; confirm a
  double-click in the header area can't be mistaken for a row
  double-click (`clickedRow == -1` guards this, but it needs checking).

**Item 1 - Disclosure-triangle expand/collapse, multiple rows at once -
strictly an opt-in Settings option.** This is the one that revisits a
recorded decision: 6.6 documents "one expansion at a time" as deliberate
(`expandedRowID: Int?` and `expandedContext` are both singular, and
"expanding a different row collapses whichever was open first").

**The default must not change.** With the new setting **off**, behavior is
exactly what ships today: one inline expansion at a time, no triangle.
With it **on**: a disclosure triangle per row, and any number of rows
expanded simultaneously.
- `expandedRowID: Int?` → a `Set<Int>`, and `expandedContext:
  (before:match:after:)?` → a `[Int: (before:match:after:)]` keyed by row
  id. Every consumer follows: `makeCell` (returns a blank `NSView()` for
  an expanded row), `tableView(_:heightOfRow:)`, `applyExpansionChange`,
  and `applyOverlay(to:row:)`.
- `applyOverlay` is the one to be careful with. It is currently the single
  idempotent add/update/remove choke point, called both eagerly and
  passively from `tableView(_:didAdd:forRow:)` - and the passive path
  exists precisely because AppKit hands back *recycled* row views that may
  carry a stale overlay from a different row. With one possible expanded
  row that check is `row == expandedRowID`; with a set it becomes set
  membership, and the "recycled view carrying a stale overlay" case gets
  strictly more likely, not less. Worth a deliberate pass.
- The `columnDidResizeNotification` observer currently renotes the height
  of the single expanded row; it must renote all of them.
- **Open question**: should the triangle also appear when the setting is
  *off* (as a nicer affordance for the existing single-expansion mode), or
  only when on? Written above as "only when on" so the default is
  byte-for-byte today's behavior, but the triangle is arguably an
  improvement in both modes. Needs a decision before implementing.

**Item 2 - Inline paragraph must not run under the Structural Attribute
column.** Also revisits a recorded decision, and the reason matters: the
full-row overlay is not incidental. The first version of 6.6's inline mode
rendered before/match/after into the existing Left/Match/Right cells and
was **rejected by the user** ("it must be an uninterrupted paragraph, not
split into left/match/right"); the fix was to pin the overlay to the *row
view's* own leading/trailing anchors, deliberately ignoring column
boundaries.

So this item is a refinement of that, not a reversal - still **one
uninterrupted paragraph**, just starting to the right of 6.2's structural
attribute column when that column is visible, so the paragraph doesn't
overlap the "Doc" value.
- Today `makeOverlayField(in:)` pins
  `field.leadingAnchor == rowView.leadingAnchor + 8`. That constant
  becomes dynamic: the right edge of the structural-attribute column when
  it's showing, via `tableView.rect(ofColumn:)` for `Column.doc`'s index.
- The column is hidden exactly when `document.structuralAttributeToShow ==
  nil` (`doc.isHidden` is set from it in two places), so that's the
  condition - and it can change at runtime, so the inset has to be
  recomputed, not just set once at overlay-creation time. The existing
  `columnDidResizeNotification` observer is the natural hook, since
  resizing the Doc column moves its right edge too.
- **Open question**: the `Column.group` (line-group) column sits *before*
  `doc`. The user's wording named only the Structural Attribute column, so
  the above insets past `doc` only - but if the group column is visible,
  the paragraph would still start over it. Settle whether the inset should
  clear *all* leading metadata columns (group + doc) or only doc.

**New settings** (both in 6.4's Concordance pane,
`ConcordanceSettingsViewController`, alongside the existing "Extended
context display: Window | Inline" control):
- `allowMultipleExtendedContexts: Bool`, default **`false`** - this is the
  Item 1 / Item 4 gate, and it governs *both* presentations from one
  switch: multiple inline expansions **and** multiple stacked windows.
  That single-setting reading is what makes the existing dangling doc
  comments (see 6.6's "Known dangling reference") correct. Default `false`
  preserves today's behavior in both modes.
- Item 1's disclosure triangle rides on the same setting rather than
  getting its own, pending the open question above.

**Implementation notes** (what the code actually ended up doing, where it
differs from or adds to the sketch above):

- `Column` gained a leading `disclosure` case, so `headerSortChanged`'s
  switch needed it too (it returns for any non-sortable column).
- The triangle cell is top-aligned on an expanded row and centered on a
  collapsed one - an expanded row's cell is as tall as the whole wrapped
  paragraph, and centering there strands the triangle halfway down, far
  from the line it belongs to.
- `makeCell` now returns real content for the metadata columns of an
  expanded row (only Left/Match/Right go blank), since the overlay no
  longer covers them.
- `tableView(_:heightOfRow:)` subtracts the overlay's leading inset from
  the available width. Without that, a row with the structural attribute
  column showing is measured wider than the paragraph actually gets to be
  and comes out too short - a bug the item 2 change would otherwise have
  introduced.
- `applyOverlay` re-applies the leading inset on *every* call, not just at
  creation: the structural attribute column can be shown/hidden or dragged
  at any time, and a recycled overlay arrives carrying the previous row's
  inset. `ExtendedContextOverlayField` holds its own leading
  `NSLayoutConstraint` so there's something to update.
- `columnDidResize` now also re-lays-out the on-screen overlays, not just
  row heights, since dragging the Doc column moves the inset.
- `settingsDidChange` shows/hides the triangle column and, if
  multi-expansion was just switched *off* while several rows were open,
  collapses them - otherwise the window would sit in a state the setting
  no longer permits, with nothing to bring it back into line.
- `toggleInlineExtendedContext` re-checks `document.rows.indices` *after*
  its `await`, since the row can be collapsed or the table replayed while
  the fetch is in flight.
- `closeExtendedContextWindows` filters `auxiliaryWindowControllers` by
  type, so Collocations/Frequency windows (which share that array but
  aren't governed by this setting) are left alone.
- Also fixed in passing: the Settings segmented control still read
  **"Sheet"** for a mode that has presented a plain window since 6.6's
  follow-up work. Now "Window", matching what it does.

**Testing.** As with 6.6 itself, none of this is engine-layer: no new
bridge primitive, no new `ManateeKit` API - all four items are AppKit
presentation over data `extendedContext(at:)`/`extendedContextInfo(at:)`
already return, so `ManateeKitTests` is untouched at 47/47.

The one genuinely unit-testable piece was extracted for exactly that
reason: `ConcordanceViewController.overlayLeadingInset(
visibleMetadataColumnWidths:intercellSpacing:textPadding:)`, a static pure
function, covered by 6 new tests in
`KorporaTests/ExtendedContextOverlayInsetTests.swift` - no visible columns
gives back plain 8pt padding (i.e. byte-for-byte 6.6 behavior), each
visible column contributes its own `intercellSpacing` gap, dropping or
widening a column shifts the inset by exactly that much, and fractional
widths (which AppKit hands out after a uniform autoresize) survive
unrounded. The live-geometry half (`overlayLeadingInset()`, which filters
`tableView.tableColumns` by visibility) stays untested, since AppKit
column geometry needs a laid-out window.

Note for whoever writes the next `#expect`: spelling an expected value as
a multi-term `+` chain on the right-hand side (`18 + 3 + 32 + …`) makes
the macro report both sides as **equal** and still fail the expectation.
Two of these tests hit that. Use a single literal and put the derivation
in a comment.

Verified: `BuildProject(buildForTesting: true)` → **BUILD SUCCEEDED**;
`RunAllTests` → **41/41 KorporaTests** (6 new); `cd ManateeKit && swift
test` → 47/47 unchanged; app launches with no constraint/exception log
output.

**Manually click-tested and confirmed working by the user 2026-09-09** -
all five planned checks: (1) with the new checkbox *off*, nothing changed
from 6.6 (no triangle column, one inline expansion at a time, a second
Window replaces the first); (2) turned on, the triangle column appears,
several rows expand at once, and each triangle collapses its own row;
(3) with a structural attribute chosen, an expanded row's paragraph starts
right of the Doc value rather than under it, and dragging the Doc column
wider moves the paragraph with it and keeps the row's height correct;
(4) double-click works in both modes, and double-clicking an expanded row
collapses it; (5) turning the checkbox off while several rows are expanded
collapses them.

So the two decisions 6.6a deliberately revisited both hold up in practice:
the opt-in default really is indistinguishable from 6.6, and insetting the
paragraph past the metadata columns didn't reintroduce the "chopped into
three pieces" look that got the original inline version rejected.

### 6.7 — New engine primitive: attribute value enumeration (done)

Shared foundation for 6.8 and 6.9, so landed once, on its own.

**Confirmed via Explore agent** (`manatee-open/corp/wordlist.hh:43-51`,
`corp/posattr.hh:71`, `corp/struct.cc:117-119,158`): `PosAttr` (and
`StructPosAttr`, which forwards straight through - so structural
attributes like `doc.author` use the *identical* interface, already
deduplicated, no manual struct-instance iteration needed) already expose:
- `id_range()` - O(1) count of distinct values (cheap enough to decide
  checkbox-list vs. search-box in the UI before fetching anything)
- `id2str(int id)` / `str2id(const char*)` - direct id↔value lookup
- `regexp2strids(pattern, ignoreCase)` - lazy, filtered (id, string) pairs
  for a search-as-you-type box (needed for high-cardinality attributes
  like `lemma`)
- `dump_str()` - the whole lexicon, for attributes small enough to show
  all at once

None of this is exposed in `mtcbridge.h`/`.cc` today - 100% new bridge
surface, but a thin wrapper (same shape as the existing attribute-name
introspection functions `mtc_corpus_attr_count`/`_name`).

**New bridge functions**: `mtc_corpus_attr_value_count(corpus, attrName,
error) -> int` (wraps `id_range()`), `mtc_corpus_attr_values(corpus,
attrName, error) -> char*` (delimiter-joined full dump, for
low-cardinality use), `mtc_corpus_attr_values_matching(corpus, attrName,
pattern, ignoreCase, error) -> char*` (wraps `regexp2strids`, for
search-as-you-type on high-cardinality attributes).

**Key files**: `mtcbridge.h`/`.cc`, `ManateeKit.swift` (new `Corpus`
methods), new `ManateeKitTests` (fixture corpus already has `doc.id`,
small `tag`/`lemma` lexicons - assert exact value lists and counts).

**Implemented as planned**, with these notes:

- `join_id_str_values(IdStrGenerator*, max_values)` is a new file-local
  helper next to `join_attr_range`, and both bridge value functions go
  through it, so the two share one encoding. That encoding is the existing
  **leading-`\x1F`-delimiter** convention (`mtc_kwic_get_left_attr`'s), not
  a plain separator - an attribute value can legitimately be the empty
  string, and leading delimiters keep "zero values" and "one empty value"
  distinguishable. The Swift side decodes with the same
  `dropFirst().components(separatedBy:)` shape `LiveConcordance` uses.
- `IdStrGenerator`'s constructor calls `next()` itself, so it arrives
  *already positioned* at its first item - the same "already started"
  convention `CollocItems` has (see `MTCCollocItems.started`) and the
  opposite of `KWICLines`. So the drain loop checks `end()` before the
  first read. Getting this backwards would silently drop the first value.
- `mtc_corpus_attr_values_matching` takes a `max_values` cap the plan
  didn't specify. It's the whole reason to prefer `regexp2strids` over
  filtering a full `dump_str`: the generator is lazy, so a cap genuinely
  stops the lexicon scan.
- Swift API: `attributeValueCount(attribute:)`,
  `attributeValues(attribute:)`, and
  `attributeValues(attribute:matching:ignoreCase:limit:)` (overloaded on
  the same base name, `ignoreCase: true`/`limit: 0` defaulted).

**Correction to this section's own premise, measured on syn2025 (122M
tokens) rather than assumed:** `doc.author` has **1,058** distinct values,
`tag` has **3,967**, `lemma` has **708,671**. So the sketch above was wrong
to call `doc.author` a low-cardinality "show everything" case - on a real
corpus even a structural attribute is well past checkbox-list territory,
and a real positional tagset is nothing like the 4 tags the fixture has.
6.8/6.9 must branch on the *measured* count, never on whether an attribute
is structural or positional. This is exactly why
`mtc_corpus_attr_value_count` exists as a separate O(1) call.

Same probe confirmed the laziness claim end to end: `matching: "pra.*"` on
`lemma` returned 1,515 values in 47ms unlimited vs 25ms with `limit: 10`,
and the limited result is a prefix of the unlimited one (so a cap takes a
prefix of a stable order, not an arbitrary subset - what
`testLimitCapsTheNumberOfMatches` asserts on the fixture).

New tests, `AttributeValuesTests.swift` (12): exact value list and count
for a small positional lexicon; count is distinct values not tokens, and
agrees with what `attributeValues` returns; a structural attribute
(`doc.id`) comes back already deduplicated; `word` vs `lemma` return their
own lexicons (the fixture inflects jumps/jump, so a mix-up is visible);
pattern filtering; **whole-value not substring matching** (`"N"` doesn't
match `"NN"`, `"N.*"` does - the reason the API doc tells callers a prefix
search needs a trailing `.*`); `ignoreCase` both ways; the limit caps and
takes a prefix; `limit: 0` means no limit; an over-large limit doesn't pad;
a pattern matching nothing is an empty list rather than an error (a search
box mid-typing hits this constantly); and all three entry points throw for
an unknown attribute.

Verified: `cd ManateeKit && swift test` → **59/59 passing** (12 new);
`BuildProject(buildForTesting: true)` → **BUILD SUCCEEDED**; `RunAllTests`
→ 41/41 `KorporaTests` unaffected. No AppKit surface yet - that's 6.8/6.9 -
so there is nothing to click-test for this item.

### 6.8 — CQL language + attribute-name completion, auto-pairing (AppKit UI done)

`CQLQueryField`'s own doc comment had flagged this as deferred
("Attribute-name/tag-value completion needs corpus registry
introspection, which isn't in the shim yet"). 6.7 made it possible.

**Scope narrowed by the user (2026-09-09), after a first version shipped
with corpus value completion.** The original sketch (and that first
implementation) completed attribute *values* out of the corpus lexicon via
6.7's `regexp2strids`. The user didn't want that: completion should cover
**the CQL language, positional and structural attribute names, and
operators** - "much more limited things" - plus **auto-closing brackets and
quotes with the caret left between them**.

That's a better feature boundary, not just a smaller one:

- Everything offered is now **small, fixed and knowable up front** - a
  keyword list, an operator list, and a corpus's schema (from registry
  metadata parsed at open time). So completion is **fully synchronous**.
- The removed version needed an async re-trigger, because
  `NSTextView.completions(forPartialWordRange:…)` is synchronous while a
  708k-entry lexicon lives on disk behind an actor: it returned nil on a
  cache miss, fetched in a `Task`, then called `complete(nil)` to reopen
  the popup. That machinery (plus a per-prefix cache that had to record
  misses to avoid re-triggering itself, an in-flight set, a 50-candidate
  cap, and regex-escaping of the typed prefix) is **all gone**.
- 6.7 is not orphaned by this - it stays, tested, and **6.9** (Text-Types
  subcorpus building) is its real consumer, which is what it was written
  for.

**Implemented** in three pieces, two of them pure and unit-tested:

- **`CQLCompletionContext`** (`Views/CQLCompletion.swift`) - a pure `enum`
  + `at(text:partialWordRange:)`, no `Corpus`, no actor, no I/O. Cases:
  `.keyword` (outside brackets), `.attributeName` (inside `[…]`),
  `.comparisonOperator` (inside `[…]` right after a name), and
  `.quotedValue` (inside `"…"` - **offers nothing**, since the contents are
  corpus data or a regex over it, and completing language keywords inside a
  string would be actively wrong). It scans *backwards* from the partial
  word deliberately: a query mid-typing (`[word=`) isn't valid CQL, so
  there's nothing to parse forwards and a real parser would reject it.
- **`CQLCompletionProvider`** - the candidate lists. `keywords` and
  `comparisonOperators` match the sets `CQLQueryField.recolor` already
  syntax-highlights, so what's completed and what's colored can't drift
  apart. Attribute names are **both kinds**: positional verbatim (`word`,
  `lemma`) plus structural in the dotted `structure.attribute` form
  (`doc.author`) that CQL accepts inside `[…]` - the same spelling
  `Corpus.structuralAttributeValue(at:attribute:)` takes - sorted, since
  the two groups arrive in unrelated registry order.
- **`CQLAutoPairing`** - pure rules over (text, selection, typed
  character), returning `.insert(text:caretOffset:)` / `.moveOver` /
  `.passThrough`. Pairs `[]`, `""`, `()`, `<>`; steps over a closer that's
  already there rather than doubling it; wraps a selection (select `fox`,
  type `"`, get `"fox"`); and backspace inside an empty pair deletes both
  halves. Applied in `InternalTextView.insertText(_:replacementRange:)`
  rather than `keyDown`, so it also covers dead keys and the character
  palette and composes with `NSTextView`'s undo grouping.

Notes:

- **`"` is both opener and closer**, so which job it does depends entirely
  on what's to the right of the caret - the step-over check runs *before*
  the open-pair check, or typing `"` at the end of `"fox"` would start a
  new string instead of finishing that one.
- Multi-character input (a paste, an IME commit) is never auto-paired;
  guessing at a pasted fragment would corrupt it.
- Operators are offered where there's **no partial word to type them
  into** (right after an attribute name), which is exactly why offering
  them as completions is worth doing at all.
- A field with **no** provider still completes keywords and operators and
  still auto-pairs - only attribute names need a corpus. So the four
  owners can be wired independently.
- `keywords`/`comparisonOperators`/`attributeNames(from:)`/`matching(_:prefix:)`
  are `nonisolated`: pure, and a provider-less field needs them from a
  synchronous AppKit callback.
- **`ManateeKit` change**: `CorpusInfo` and `StructureInfo` had `public
  let`s but only synthesized *internal* initializers, so a client could
  read one but never build one - which blocked unit-testing anything that
  takes a `CorpusInfo`. Both now have public memberwise inits.

**Wired three of the four CQL fields, not the two the sketch named** -
there are four (`grep 'CQLQueryField()'`):

| Field | Wired | Why |
| --- | --- | --- |
| `ConcordanceViewController` query bar | yes | `document.corpusName` |
| `NewConcordanceSheetController` | yes | rebuilt per selected corpus from the `info()` it already fetches; cleared on the no-corpus and error paths |
| `FilterSheetController` | yes | same bracketed CQL against the same corpus - completion in one field but not the other would just look broken. Needed only a `corpusName` pass-through from its presenter |
| `NewSubcorpusPopoverController` | **no** | it edits an *unbracketed* structure-attribute expression (`author="Twain"` - see `Corpus.createSubcorpus`), so attribute-name completion there needs different rules. Auto-pairing works there already, since that's field-wide |

The query bar deliberately completes against the **corpus**, not the
subcorpus: a subcorpus restricts which *hits* come back, not which
attributes exist, and it shares the parent's schema anyway.

New tests, `KorporaTests` (38): `CQLCompletionContextTests` (18) covers
every position that behaves differently - inside an open bracket, after a
closed one, a second attribute after a completed `="…"` pair, after a
boolean `&`, empty prefixes right after `[` (full attribute list) and after
a name (operators), operator position with and without a space and after a
dotted name, `[word=` *not* being operator position, all four quoted-value
situations including an **escaped quote not closing the string**, and an
out-of-bounds range (which a stale completion request after an edit can
produce) clamping rather than trapping. `CQLCompletionCandidateTests` (5)
covers the dotted structural form, a structure with no attributes of its
own contributing nothing, empty-prefix-offers-everything, case-insensitive
matching, and nil-for-no-matches. `CQLAutoPairingTests` (15) covers each
pair, both step-over cases, selection wrapping, pass-through for ordinary
and multi-character input, and all five backspace situations.

Verified: `BuildProject(buildForTesting: true)` → **BUILD SUCCEEDED**;
`RunAllTests` → **79/79 KorporaTests**; `cd ManateeKit && swift test` →
59/59; app launches with no exception/constraint output. **Not yet
manually click-tested** - next steps: type `[` and confirm it becomes `[]`
with the caret inside and the attribute list appears (Escape/F5 if the
popup needs asking); confirm both `word`-style and `doc.author`-style names
are listed; space after a name and confirm `=`/`!=`/`<`/`>` are offered;
type `"` and confirm the pair, then type `"` again at the closing quote and
confirm the caret steps over rather than doubling; backspace inside a fresh
`[]` and confirm both halves go; select a word and type `"` to wrap it;
confirm nothing is offered inside a quoted value; confirm `within` still
completes outside brackets; and confirm the same in the New Concordance and
Filter sheets, including that switching corpus swaps the attribute names.

### 6.9 — Text-Types-style subcorpus creation (not started)

Today, `NewSubcorpusPopoverController` takes a free-text CQL restriction
(`author="Twain"`, `queryField` is a plain `CQLQueryField`). KonText
instead shows checkboxes of the actual distinct values for a chosen
structural attribute.

**Design**: replace the free-text field with an attribute pop-up
(populated from `corpusInfo.structures[selected].attributes` - the same
discovery already used for the structure pop-up itself) plus a checklist
of that attribute's distinct values, fetched via 6.7 (`dump_str()` if
`id_range()` is small, else a search field feeding `regexp2strids`).
Selected values compile to the existing CQL restriction string format
under the hood (`author="Twain"|author="Poe"` for OR-of-values) - so
`Corpus.createSubcorpus`'s existing contract is unchanged, this only
changes how the query STRING gets built, not how it's used.

**Key files**: `NewSubcorpusPopoverController.swift` (main rework),
reuses 6.7's new `Corpus` methods.

**Verify**: `ManateeKitTests` unchanged (subcorpus creation API itself
doesn't change); manual test creating a subcorpus via checkboxes and
confirming its size/content matches picking the same values by hand via
free-text CQL today.

### 6.10 — Charts: Collocations/Frequency + concordance dispersion plot (not started)

**User-confirmed approach**: Swift Charts + `NSHostingView` - the
project's first SwiftUI usage, confirmed feasible with zero project-level
changes needed (deployment target is already macOS 27, `ManateeKit`
already targets macOS 13+; Explore agent confirmed no build-setting
changes required beyond regenerating the Xcode project via `xcodegen` so
new files are picked up).

**Design**:
- A reusable SwiftUI `BarChartView` (label + value pairs), used by both
  `CollocationWindowController` (data already has exactly the right
  shape: `CollocationItem.word`/`.score` or `.freq`) and
  `FrequencyWindowController` (`FrequencyItem.word`/`.freq`) - both
  currently plain `NSTableView`s with no charting (confirmed via Explore
  agent). Add a toolbar segmented control, "Table | Chart", toggling
  `window.contentViewController`'s content between the existing table and
  a new `NSHostingController(rootView: BarChartView(...))`.
- **Concordance dispersion plot**: a small histogram/strip-plot of hit
  positions across the corpus (0-100%), using data *already on hand* -
  every row's `position` (already on `KWICLine`) plus `corpusSize`
  (already fetched in `replay()`) - no new engine work for the chart
  itself. **Important design note**: build this from a lightweight
  "positions of every hit" fetch that's independent of however many rows
  happen to be materialized/paginated in the visible table (see 6.11) -
  i.e. don't wire the dispersion plot to `document.rows`, wire it to a
  new cheap position-only bridge call (`RS(true,0,0)` + `beg_at` per
  index, skipping all token/text decoding) so it stays correct once 6.11
  lands regardless of build order between the two.
- Printing/exporting a chart is close to free once it exists: the
  existing `NSPrintOperation`/`drawPageBorder` pattern
  (`ConcordanceViewController.printConcordance`) works on any `NSView`
  including an `NSHostingView`; "export" for these windows = print/export
  whatever's currently shown (table or chart), matching the concordance
  window's own existing behavior rather than adding a second code path.

**Key files**: new `Views/BarChartView.swift` (SwiftUI), new bridge
function for dispersion positions, `CollocationWindowController.swift`,
`FrequencyWindowController.swift`, `ConcordanceWindowController.swift`
(dispersion plot placement - likely a new toolbar button opening an
auxiliary window, same `show(_:)` pattern as Collocations/Frequency).

**Verify**: `BuildProject`(after `xcodegen generate`) to confirm the
SwiftUI/AppKit bridge compiles cleanly; manual visual check (first
SwiftUI content in the app - check dark mode, VoiceOver labels default
reasonably); `ManateeKitTests` for the new position-fetch primitive.

### 6.11 — Concordance result pagination/streaming (not started)

Biggest, most structurally invasive item - deliberately last. **Explore
agent's verdict: cheap in principle** - fetch depth is already orthogonal
to the sort/filter/shuffle/sample operation chain (confirmed:
`ConcordanceOperation.apply(to:)` only mutates manatee's own live view;
`refetchDisplay()` already proves lines can be re-fetched independently
of re-running operations) - but touches several call sites.

**What already exists, engine-side** (no manatee-open changes needed):
- `Concordance::RS(useview, beg, end)` (`concord.hh:173`) - O(1) seek to
  a `[beg, end)` window, already used by the bridge with default
  `beg=0, end=0` (whole set) at `mtcbridge.cc:193`.
- `mtc_concordance_size` (`mtcbridge.cc:176`) - already exposes total hit
  count cheaply, already surfaced as `LiveConcordance.count`
  (`LiveConcordance.swift:250`) but currently **unused** by the app
  (hit count today comes from `lines.count` after fetching everything).

**Concrete changes needed** (all confirmed by Explore agent, no
surprises):
1. `mtc_kwic_open` + `LiveConcordance.kwicLines` gain `offset`/`limit`
   parameters, bounding the `while mtc_kwic_next(kwic) != 0` loop
   (`LiveConcordance.swift:361`).
2. `buildRows` (`ConcordanceDocument.swift:368-379`) currently uses the
   fetched-array offset as both row `id` and the argument to
   `live.linegroup(at:)` - must become a real global index once fewer
   than all lines are fetched.
3. Descending sort is currently faked by reversing the *whole* materialized
   array (`ConcordanceDocument.swift:374-378`) - needs to become index
   arithmetic against the total count (`RS(true, total-end, total-beg)`
   then reverse just that page) instead of an in-memory reverse.
4. `ConcordanceViewController`'s diffable-snapshot feed, the CSV/TSV
   exporter, and the Operations popover's line-group counts
   (`updateOperationsPopover`) all currently assume `document.rows` holds
   *everything* - each needs an explicit decision: does Export always
   fetch the full set regardless of what's paginated on screen (almost
   certainly yes - a user exporting expects everything, not just the
   visible page), and does the line-group count in Operations need a
   separate full-corpus-scoped query, or can it stay approximate/loading
   for huge results?

This item needs its own follow-up research/design pass immediately before
implementation (specifically: nail down the exact `NSTableView`
"load more on scroll" vs. "Next/Previous page" UX, and the Export
full-fetch question above) rather than being fully speced now - flagging
it here as the last, most-open-ended item in the roadmap rather than
writing pseudocode that's likely to need revision once the UX is chosen.

**Verify**: `ManateeKitTests` for windowed fetch correctness (assert
`kwicLines(offset:limit:)` against a fixture with a known hit count
returns the right slice); manual test against a real large corpus
(syn2025) confirming responsiveness improves and line-groups/sort/filter
still behave correctly across pages.

### Verification (all of Phase 6)

Same pattern as every prior phase in this project:
- `cd ManateeKit && swift test` after any engine/bridge/Swift-API change.
- `BuildProject(buildForTesting: true)` then `RunAllTests` after any
  AppKit change (run `xcodegen generate` first if new files were added).
- Manual click-through in Xcode for anything touching live UI/rendering
  (per this project's division of labor - visual/interactive verification
  happens in the Xcode agent session, not headless).
- Update this section incrementally, one sub-phase at a time, following
  the exact Phase 5 writeup pattern (engine/bridge summary → AppKit
  summary → test counts → "not yet manually click-tested" caveat → wait
  for user confirmation before commit) - not all at once at the end.

## Key files

- `ManateeKit/Sources/CManatee/include/mtcbridge.h`,
  `ManateeKit/Sources/CManatee/mtcbridge.cc` — the whole C shim surface
- `ManateeKit/Sources/ManateeKit/ManateeKit.swift`, `LiveConcordance.swift`,
  `SubcorpusStore.swift`, `CorpusRegistry.swift` — the Swift engine API
- `ManateeKit/Tests/ManateeKitTests/` — 32 passing tests; run with `cd
  ManateeKit && swift test`
- `manatee-open/concord/concgrp.cc` — the fixed upstream bug, on
  `stranak/manatee-open`'s `macos-arm64-portability` branch (pushed, not
  yet a PR)
- `Corpora/` — the Xcode project and all AppKit sources; `project.yml` for
  xcodegen; `scripts/build-dev-corpus.sh` for the dev-only test corpus
