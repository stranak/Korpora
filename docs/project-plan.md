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
- **Tests**: ManateeKit's tests are XCTest, not this workspace's usual Swift
  Testing convention — a known divergence, not something to rewrite
  speculatively.

## Status summary

| Phase | Engine (ManateeKit/CManatee) | AppKit UI | Visually verified |
|---|---|---|---|
| 0 — AppKit shell, NSDocument, query parity | done | done | yes (screenshots, earlier session) |
| 1 — sort/filter/shuffle/sample/line-groups | done, 17 tests passing (cumulative) | done, plus header-click-sort + Operations popover (2026-09-05) | **partial — core toolbar ops confirmed by user (sort, sample, filter); header-click-sort confirmed; Operations popover not yet manually verified; row context menu/undo not yet re-verified since the 2026-09-05 additions** |
| Settings (Cmd-,) | n/a | done | yes (screenshots, earlier session) |
| 2 — corpus info + subcorpus management | done, 17/17 tests passing | done, builds & launches cleanly | **partial — user manually verified Settings (bug found & fixed) and Sort (confirmed correct); subcorpus flow (item 3) still outstanding; see verification log** |
| 3 — collocations, frequency distributions | not started (sketch only) | not started | n/a |

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
  tabbing. Toolbar (Sort/Filter/Shuffle/Sample/Clear Groups, custom
  `NSButton`-backed items). Query bar (`CQLQueryField`) + status label +
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
  Shuffle/Sample disable and Clear Groups enables (mirrors KonText's own
  rule) — verified visually earlier.
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
  ("Operations", `list.bullet`) lists every active sort/filter/shuffle/
  sample with a per-row remove button (`OperationsPopoverController`) —
  requested after manual testing found that Undo alone (which can only
  unwind the *most recent* operation) wasn't flexible enough to drop one
  specific sort or filter out of the middle of a chain. `ConcordanceOperation`
  gained a `summary` computed property (human-readable label) and
  `ConcordanceDocument` gained `removeOperation(at:)`, which reuses the same
  `setOperations` path every other mutation goes through — so removing one
  operation this way is itself undoable via Cmd-Z, consistent with
  everything else. Line-group operations are deliberately excluded from this
  list (they already have their own bulk "Clear Groups" button, and there
  can be many of them - one per line group assignment). This button stays
  enabled even when line groups are active (unlike Sort/Filter/Shuffle/
  Sample), since reviewing/removing *existing* operations doesn't conflict
  with an active line-group view the way starting a *new* one would.
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
  Content still follows the original doc 1/2 pattern (DT-JJ-NN-VBZ
  sentences, plus doc 1's original DT-JJ-JJ-NN-VBZ sentence testing that
  `[tag="JJ"][tag="NN"]` doesn't match a JJ-JJ pair) — 41 tokens total,
  verified via `swift run manateekit-cli testcorp '[tag="JJ"][tag="NN"]'`
  against `DevCorpus/registry`: exactly the 10 expected JJ+NN matches
  (brown fox, lazy dog, curious cat, sleepy cat, elegant lady, proud
  gentleman, local market, global economy, annual report, modest profit),
  one per sentence, in document order. Subcorpus creation itself with these
  *specific* attribute names hasn't been separately verified — `RunCodeSnippet`
  can't link CManatee's C++ symbols (JIT limitation, not a corpus defect),
  so this relies on the same generic `create_subcorpus`/`openSubcorpus` code
  path already covered by `SubcorpusTests` (which uses `id`, not `author`/
  `genre`/`year` — Manatee's structural-attribute lookup doesn't special-case
  any particular name, so there's no reason to expect different behavior,
  but it's still worth the user's manual click-through confirming it).

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
3. Try "New Subcorpus…" a few different ways (see the semantic note above —
   no brackets, no attribute prefix):
   - name `twain`, structure `doc`, restrict-to `author="twain"` → should
     match docs 1+2 (2 of 5 documents, 17 tokens — doc 1 has 9, since its
     first sentence has an extra adjective, "quick brown fox").
   - name `fiction`, structure `doc`, restrict-to `genre="fiction"` → docs
     1+2+3 (3 of 5, 25 tokens).
   - name `news2021`, structure `doc`, restrict-to `year="2021"` → doc 5
     only (8 tokens).
   Confirm each appears in the Subcorpus popup, and that selecting one +
   searching `[tag="JJ"][tag="NN"]` restricts results to exactly that
   subset's matches (e.g. `twain` → brown fox, lazy dog, curious cat, sleepy
   cat) with the status line reading "...subcorpus "name"".
4. Spot-check Phase 1's toolbar (Sort/Filter/Shuffle/Sample/Clear Groups),
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
Phase 2's writeup above), also **not yet manually verified**. Still
outstanding: the Operations popover, the expanded subcorpus flow, and the
row context menu.

## Phase 3 (sketch, not started) — Analysis views

Collocations via `CollocItems` (`concord/concstat.hh`) — per-word
freq/count plus MI/T-score/logDice-family association measures. Frequency
distributions/word lists via `Corpus::freq_dist` and
`count_structattr_vals`. Likely surfaces as new window/panel types (or new
`NSDocument` subclasses) driven off an existing `LiveConcordance`. No shim
work exists yet — plan this properly when it's next up.

## Key files

- `ManateeKit/Sources/CManatee/include/mtcbridge.h`,
  `ManateeKit/Sources/CManatee/mtcbridge.cc` — the whole C shim surface
- `ManateeKit/Sources/ManateeKit/ManateeKit.swift`, `LiveConcordance.swift`,
  `SubcorpusStore.swift`, `CorpusRegistry.swift` — the Swift engine API
- `ManateeKit/Tests/ManateeKitTests/` — 17 passing tests; run with `cd
  ManateeKit && swift test`
- `manatee-open/concord/concgrp.cc` — the fixed upstream bug, on
  `stranak/manatee-open`'s `macos-arm64-portability` branch (pushed, not
  yet a PR)
- `Corpora/` — the Xcode project and all AppKit sources; `project.yml` for
  xcodegen; `scripts/build-dev-corpus.sh` for the dev-only test corpus
