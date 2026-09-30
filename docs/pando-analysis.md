# pando as a syntax-aware engine for Korpora - analysis (2026-09-30)

## Context

Korpora is built on manatee-open (KonText's engine). Manatee only sees a linear token stream with
structure spans, so a parsed corpus gets its syntax flattened into positional attributes (head, deprel)
that CQL cannot join on. `ufal/pando` is a new C++ engine "in the same family" with native dependency
queries, and its `dcoll` command (collocates along dependency edges) is the raw material for
parse-based word profiles ("word sketches" without hand-written grammars).

The user asked for a proper analysis of two options, for both small (treebank) and billion-token
(SYN2025-scale) corpora:

1. pando as a **second engine**, Manatee stays.
2. pando as a **full replacement** of Manatee.

This document is the analysis only; nothing has been built or measured yet. Status: proposal, awaiting a decision on Phase A.

## What pando is (verified from github.com/ufal/pando, 2026-09-30)

- Public GitHub repo, created 2026-03-17, **37 commits, one author (Maarten Janssen, TEITOK)**, 0 stars,
  0 issues, no releases. **No license** (README: "private and experimental"). The user says the author is a
  colleague and licensing is not a problem, so this is a paperwork item, not a blocker.
- C++17, CMake, mmap index directory (`corpus.info`, `.dat/.lex/.rev`, `dep.*`). macOS and Linux;
  developed on macOS. Tools: `pando` (CLI), `pando-index`, `pando-check`, `pando-server` (HTTP/JSON),
  `cwb_import` (CWB import).
- **Embeddable**: `src/api/pando_ffi.h` is a small C API (`pando_open`, `pando_query`, `pando_run`,
  `pando_info`, `pando_free_string`, `pando_close`), JSON in/out, one handle per thread. This is the
  same shape as our `mtcbridge`, and much smaller (6 functions vs 61).
- **Query language**: pando-CQL is modelled on CWB CQL with additions: dependency operators
  (`>`, `<`, `>>`, `<<`), tree restrictions (`[upos="NOUN" & child [upos="DET"]]`, `not child`),
  named tokens, `within`/`containing`, aligned corpora, multivalue and UD-feats attributes,
  `count/freq/coll/dcoll/keyness/stats/tabulate`. A `--cql cwb` dialect exists but is a **subset**
  (no `within`, no `::`, no `|` between sequences). So existing Manatee CQL queries do not carry over
  verbatim, and users of KonText-style CQL would notice.
- **Maturity signals**: README says APIs, formats and flags change without notice; only a handful of
  unit-test files in `src/`; recent commits are performance work (bitset dependency join, Manatee-style
  `.rev` shift-merge). The only scale statement in the docs is the sample script: full UD, "tens of
  millions of tokens". **No published numbers for billion-token corpora or index-build memory.**

## Where Korpora is coupled to Manatee (Explore result)

No abstraction exists: every ManateeKit type is concrete, 21 app files import it, and the plan
never considered another engine. Coupling by layer:

| Layer | Coupling | What replacing/adding an engine costs |
|---|---|---|
| `CManatee` bridge (61 C functions), `ManateeKit` (1,900 lines) | total | New bridge for pando (FFI: ~6 calls + JSON parsing) |
| `ConcordanceDocument` (757 lines), operation types, exporter, KWIC formatter | high: builds `Corpus`/`LiveConcordance` directly; persisted `.corpconc` JSON embeds Manatee shapes (`SortCriteria`, `PNFilterSpec`, `subcorpusPath`), no version field | Needs engine protocols and a versioned document format |
| CQL editing: `CQLQueryField` colouring, `CQLCompletion`, `SubcorpusRestriction` | Manatee CQL and regex-escaping rules baked in | Per-engine language front end |
| Corpus management: registry files, `MANATEE_REGISTRY`, `encodevert`/`mkregexattr` import, `.subc` subcorpora, residency warming | high | pando has directories, not registries; no import UI counterpart; **no persistent subcorpus object** (named queries act as subcorpora) |
| Release: static pcre2, manatee worktree, bundled helpers, signing | build-only | pando needs only CMake and vendored httplib; would simplify release |
| Tests | ManateeKit 112 (all engine-coupled), app 160 (~105 import ManateeKit) | Full replacement invalidates most; second engine adds tests |

Useful seams already present: `CorpusInfo`/`StructureInfo` plain structs, `CQLCompletionContext.at(text:)`
pure function, engine-free `CorpusMemoryResidency`.

## Option 2: full replacement — assessment

Not recommended now. Reasons, in order of weight:
1. **Scale unknown.** SYN2025 is the app's real workload (7.4 GB index, 20+ attributes). Pando has no
   evidence at that size; Manatee is proven there.
2. **Feature parity gaps** for what Korpora ships: persistent subcorpora (`.subc`, the 6.9 value picker),
   sort/filter/shuffle/sample/line-group operations on a live concordance handle, Bonito-style contexts,
   KWIC pagination via `RS(beg,end)`, cooperative cancellation. Pando's FFI is stateless JSON per query
   plus session named queries; each of these would have to be re-derived or added upstream.
3. **Compile pipeline**: users import verticals via `encodevert`; pando indexes JSONL/CoNLL-U. A vertical
   importer would need writing.
4. **Bus factor and format stability**: one author, pre-release formats; every pando format change forces
   a reindex of multi-GB corpora.
5. **Query-language break** for existing KonText users and our saved `.corpconc` files.
Upside that stays true: simpler release (no pcre2, no fork of manatee-open with its own heap-corruption
fix), one engine to reason about.

## Option 1: second engine — recommended path

Manatee remains the default and the workhorse for large flat corpora. Pando is opened for **parsed**
corpora (CoNLL-U/UD, TEITOK exports), where its strengths apply. Corpora carry an engine tag.

Phased, each phase shippable and stoppable:

**Phase A — evidence spike (time-boxed, no app changes).** A "spike" here means a small throwaway
experiment to answer the open questions before committing to design, then discarding or keeping only
the notes. Concretely, in a scratch directory outside the repo:
- Build pando on this Mac (arm64, macOS 27) and on the macOS 15 floor; record build time and problems.
- Index `data/ud-en-ewt` and full UD (tens of millions of tokens); time indexing, index size, RAM.
- Index a **large** parsed Czech corpus slice (10^8–10^9 tokens) or a synthetic one to find the ceiling;
  measure dependency-join and `dcoll` latency and index-build memory.
- Drive `libpando` through the C FFI from a small Swift test: `pando_run` for KWIC, `count`, `dcoll`;
  check thread-safety and the JSON schema stability, and whether session state survives.
- Run 20 representative CQL queries from our tests through native and `--cql cwb` and log what breaks.
- Word-profile prototype: for one lemma, run `dcoll` per relation (nsubj, obj, amod, nmod, …), rank by
  logDice, and compare with what Sketch Engine shows for the same lemma (it already supports
  dependency-parser-fed sketches: sketch grammar output "is formally a dependency parse").
- Ask the author: license (agreed), format-stability plans, subcorpus and pagination plans, whether the
  FFI can expose a cancellable handle.
Output: `docs/pando-analysis.md` results table and a go/no-go per capability.

**Phase B — engine seam (only if A is go).** Extract `CorpusEngine` / `Concordance` protocols from the
concrete Manatee types (targets: `ConcordanceDocument`, `Corpus`, `LiveConcordance`,
`FrequencyCriterion`, `SortCriteria`), keep ManateeKit as the implementation, move engine-specific
persisted fields behind a versioned `.corpconc` format with migration. No behaviour change; existing
272 tests stay green. This step is useful even if pando is later dropped (also unblocks 6.11 pagination).

**Phase C — PandoKit + tree queries.** New Swift package over `libpando` FFI (built as a static lib in
`build-release-deps.sh`, replacing nothing). Corpus list gets an engine column; "Add corpus" accepts a
pando index directory. Query field gets a pando-CQL mode (highlighting, dependency operators in
completion). Unsupported operations (sort criteria, line groups) are disabled per engine capability
flags rather than emulated.

**Phase D — word profiles (the feature of interest).**
- Data: `dcoll <rel> by lemma` per relation for a node lemma+POS; symmetric relations (nmod/obl with
  case markers, conj) need small UD-aware post-processing. Measures logDice/MI/T-score exist.
- Sketch-style grouping is done in UD terms (relation labels), not hand-written grammars, and works for
  any language with a parse; languages without one are out of scope.
- UI (AppKit, our hand-drawn charts are reusable): one window, columns per relation (subject-of, object-of,
  modifiers, prepositional/oblique, coordination), each a ranked list with logDice bars; double-click
  opens the concordance of that pair (a pando `dependency` query); lemma/POS picker; "compare two
  words" (sketch difference) as a second mode.
- Depends on Phase C, and on a parsed corpus; also needs a pipeline to *produce* parsed corpora
  (UDPipe/flexipipe → CoNLL-U → `pando-index`), which could be a later "Parse and import" feature.

**Alternative for word profiles without pando** (cheaper fallback, recorded for the analysis): parse with
UDPipe, precompute a triples table (head lemma, relation, dependent lemma, frequency, position pointers)
in our own store, compute logDice ourselves. Fast at any corpus size and engine-independent, but
drill-down to concordance needs Manatee-side positions or pando anyway, and tree queries are lost.
Phase A should quantify whether pando's `dcoll` is fast enough on big corpora to make this unnecessary.

## Recommendation

Do **not** replace Manatee. Run Phase A now (a few days of work, no risk), decide from its numbers.
If scale and FFI hold up, do B → C → D. If pando fails on large corpora, keep it for treebank-scale
corpora only, or take the triples-table fallback for word profiles.

## Critical files (for the follow-up implementation, not for this analysis)

- `ManateeKit/Sources/CManatee/include/mtcbridge.h`, `mtcbridge.cc` — bridge to mirror for FFI
- `ManateeKit/Sources/ManateeKit/ManateeKit.swift`, `LiveConcordance.swift` — types to abstract
- `Korpora/Korpora/Documents/ConcordanceDocument.swift` — main coupling point, persistence at ~691–757
- `Korpora/Korpora/Views/CQLQueryField.swift`, `CQLCompletion.swift` — language front end
- `ManateeKit/Sources/ManateeKit/CorpusLibrary.swift`, `CorpusRegistry.swift`, `CorpusImporter.swift` — corpus list/import
- `scripts/build-release-deps.sh`, `scripts/make-release.sh`, `Korpora/project.yml` — release plumbing
- Reusable for the profile UI: `Views/BarChartView.swift`, `PaperSafeDrawing.swift`, `WindowPrinting.swift`

## How the claims here were checked

- Every pando claim in the write-up is sourced from the repo files above (`README.md`, `wiki/*`,
  `src/api/pando_ffi.h`) or measured in Phase A; unknowns stay marked as unknown.
- Coupling table cross-checked against the Explore report and `docs/project-plan.md`.
- Phase A results table filled with measured numbers before any go/no-go is stated.
