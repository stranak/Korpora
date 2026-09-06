# Corpora: native AppKit corpus concordancer — status & handoff

This is the living status/handoff document for this project. It lives at
`docs/project-plan.md` in the repo (not `~/.claude/plans/` or anywhere
outside the checkout) so any session — Terminal or Xcode — can read and
update it, and so code comments can cite it by a stable path. See the root
`CLAUDE.md` for the convention.

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

- **`github.com/stranak/mac-corpora`, branch `main`** — the pushed baseline.
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

`manatee-open` itself is **not pinned** by anything in `mac-corpora` — it's
excluded via `.gitignore` and `scripts/setup-dev-machine.sh` only checks
that a `manatee-open` checkout exists next to this repo, it doesn't clone or
check out a branch. On a fresh machine, clone it explicitly and check out
the right branch *before* running that script:

```
git clone -b macos-arm64-portability https://github.com/stranak/manatee-open.git
```

Otherwise the build silently uses unpatched upstream `manatee-open`,
including the reverted `delete_linegroups` heap corruption.

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

All Swift/C++ code builds cleanly and all ManateeKit tests pass (`swift
test` → 17/17).

## Phase 0 — AppKit shell, NSDocument model, query parity (done)

- `Corpora/Corpora.xcodeproj`, generated via `xcodegen` from
  `Corpora/project.yml`, sibling to `ManateeKit/`. Depends on `ManateeKit`
  as a local Swift package. Regenerate with `cd Corpora && xcodegen
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
- `Corpora/Corpora.entitlements`: sandboxing explicitly disabled
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

1. Open `Corpora/Corpora.xcodeproj`. If `DevCorpus/` doesn't exist, run
   `Corpora/scripts/build-dev-corpus.sh` once (idempotent). The Xcode
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

Verified: `cd ManateeKit && swift build` (compiles; still shows the
Package.swift-side linker warnings, expected) + `swift test` → 34/34
passing; `xcodegen generate` + `xcodebuild -scheme Corpora clean build` →
**BUILD SUCCEEDED**, warning count 41 → 6; `xcodebuild -scheme Corpora
test` → 8/8 `CorporaTests` passing.

**Still not manually click-tested end-to-end** — re-running the SYN2025
import with all of this session's fixes (including the actual crash still
being unexplained) is the next step, along with the original Keep in
Memory toggle/guard verification.

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
