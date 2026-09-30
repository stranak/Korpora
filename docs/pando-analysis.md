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

This document is the analysis only; nothing has been built or measured yet. Status: Phase A (measurement spike) done 2026-09-30, results below. Decision on next steps open.

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

## Phase A results (measured 2026-09-30)

Setup: pando `main` at `8952b6d` (37 commits), built with CMake 4.4 + Ninja from a pip venv, on an M-series
Mac (32 cores, 512 GB RAM, macOS 27, Xcode 27), in `~/Developer/pando-spike/` outside the repo. macOS 15
checks ran in the existing Tart VM (15.7.7, 4 cores). Real data: UD English-EWT (255k tokens, real
parses). **Large data is synthetic**: Zipfian lemmas (vocabulary 1M), sentences of ~20 tokens, random
trees, 30 relation labels, 10 POS. It tests engine scale, not linguistic realism; real corpora will differ
in selectivity. All timings are warm-cache (files just written, 512 GB RAM): **cold-cache numbers were not
measured** (`purge` needs root).

### Build and platform
| Check | Result |
|---|---|
| Clean build (62 targets) | ~11 s, 1 warning, no changes needed |
| Default deployment target | macOS 27 (`minos 27.0`), so a release build must set `CMAKE_OSX_DEPLOYMENT_TARGET=15.0`; with it, it builds cleanly and the CLI runs on the macOS 15.7.7 VM |
| Shared lib (`-DPANDO_BUILD_SHARED=ON`) | `libpando.dylib`, 1 MB, depends only on libc++/libSystem, exports the 6 `pando_*` functions |
| Bundled test binaries | 3 of 4 pass; `mv_stage1_executor_test` fails (`parallel_matches.size() == 1u`, line 136); `cwb_dialect_test` prints nothing (exit 0) |

### Indexing and scale (synthetic corpora, single process)
| Corpus | Index time | Peak RSS | Index size |
|---|---|---|---|
| EWT 255k tokens (real) | 0.4 s | 144 MB | 15 MB |
| 10M tokens | 8 s | 457 MB | 477 MB |
| 100M tokens | 90 s | 2.0 GB | 4.2 GB |
| **1,000M tokens** | **14.7 min** | **18.4 GB** (footprint 7 GB) | **41 GB** |
Roughly linear: ~1.1 M tokens/s and ~41 bytes per token with 7 attributes plus dependencies. (Manatee's
SYN2025 index is 7.4 GB, but has different content and token count, so this is not a like-for-like size
comparison.) Index build must run on a machine with ~20 GB free RAM at 1B tokens.

### Query latency (warm)
| Query | 10M | 100M | 1B |
|---|---|---|---|
| `[lemma="l5"]` (1.3% of tokens), 5 hits + total | 0.03 s | 0.08 s | 0.70 s |
| rare lemma | 0.02 s | 0.03 s | 0.12 s |
| `[lemma="l3"] > [upos="NOUN"]` (dependency) | 0.03 s | 0.11 s | 1.06 s |
| `[lemma="l40"] >> [lemma="l7"]` (descendant) | 0.04 s | 0.17 s | 1.72 s |
| noun with `child nsubj` and `child obj` | 0.18 s | 1.7 s | 20.4 s |
| `dcoll nsubj by lemma`, very frequent node (13M hits) | 0.08 s | 0.64 s | 7.3 s |
| `dcoll nsubj by lemma`, mid-frequency node | - | - | 0.13 s |
| `coll by lemma`, very frequent node | 0.09 s | 0.64 s | 7.9 s |
| `count by form`, 13M hits | 0.03 s | 0.06 s | 0.41 s |
Conclusion: interactive at 100M tokens for everything measured; at 1B tokens interactive for selective
queries and single-relation collocations, seconds for very frequent nodes, ~20 s for multi-child tree
restrictions over all nouns. A full word profile is one `dcoll` per relation: ~10 relations x <1 s for
typical lemmas, up to ~1 min for the most frequent lemmas at 1B tokens.

### C API (`libpando`) - works, with three problems
- Works: `pando_info`, `pando_query` (hits with context, per-token attributes, exact totals),
  `pando_run` (programs: `count`, `dcoll`, ...), named-query session state persists across `pando_run`
  calls on one handle, bad queries return `{"ok":false,...}`, a missing corpus returns NULL. JSON is rich
  and well structured. Four threads with four separate handles: 800/800 queries on macOS 27.
- **Bug: the relation argument of `dcoll` is dropped through the API** (`"relations": []`; `obj`,
  `nsubj` and none all return the same list), while the CLI honours it. So the engine logic is in the CLI
  (`query_main.cpp`, 174 KB) and the API layer lags behind it. Word profiles through the API are blocked
  until this is fixed (or we shell out to the CLI/`pando-server`).
- **Bug: `pando_open` fails under concurrent opens when the file-descriptor limit is low.** Pando keeps one
  file descriptor open per index file for the lifetime of the mapping (79 for the tiny EWT index; large
  corpora have many more). macOS's default soft limit is 256, so on the VM 4 concurrent opens failed in
  most runs; after `ulimit -n 4096`, 48/48 passed. A GUI app can raise its own limit, but mmap does not
  need the descriptor after mapping, so this is an easy upstream fix.
- Minor: errors carry no message (`"query execution failed"`), and the option keys for `pando_run` are not documented (I did not establish which are honoured).

### Query-language compatibility (24 Manatee/KonText-style queries, native and `--cql cwb`)
Works in both: `[form="x"]`, `[lemma=..]`, `&`, `|` inside `[ ]`, regex, `{m,n}` on `[]`, `!=`, `%c`,
top-level named tokens with `::` (native only). `[word=..]` is accepted (aliased to `form`).
Fails or differs, in native and (more so) the CWB dialect:
- `within <s/>`, `within <doc/>` (Manatee/CQP XML-tag syntax); pando uses `within s`. `<s> [..] </s>` returned
  **0 hits silently** instead of an error.
- Parenthesised groups with repetition `([..] [..])+` and `{1,2}`: error in both.
- `containing` with a token pattern (pando: `within s having [..]`); `1:`-style numeric labels with
  Manatee's `&` global constraints; `!( ... )` negation; top-level `|` between sequences (CWB dialect only).
- Attribute names differ (`form`, `upos`, `xpos`, `deprel`, `feats` instead of `word`, `tag`).
So the CWB dialect does not make KonText-style queries portable; the app would need a pando-specific
query mode, and saved queries would not transfer between engines.
Minor quirk: `a.form` in `count M by a.form` resolved to the `contr` region's `form` attribute and returned 0
groups on EWT (works with `a.lemma`, or plain `form`); attribute names collide with region attributes.

### Word-profile prototype (real parse, EWT), one `dcoll` per relation
- `eat` (VERB): `nsubj` he, people, they, I, you, we; `obj` hay, grain, meat, cream, food; `obl` Miramar,
  restaurant, hand. `book` (NOUN, `deprel="obj"`, `dcoll head`): write, read; `book` heads: write, author,
  read. Linguistically sensible with no grammar written.
- Limits seen: (1) the `freq` column is the collocate's corpus-wide frequency, not the frequency of the
  relation triple, so logDice differs from Sketch Engine's per-relation score; (2) prepositional relations
  (obl + case marker) and coordination need extra work; (3) one query per relation, no single-pass
  profile. A comparison against Sketch Engine itself was **not done** (no access from here); it remains a
  to-do for someone with an account.

### Not tested
`pando-server` (HTTP); subcorpus-style restriction on a text attribute at 1B; cold-cache latency; concurrent
queries on one handle; real parsed Czech data at scale; memory use while serving (mmap, so shared with
the OS cache); cancellation (no API for it: a query cannot be interrupted).

### What the results change
- **Scale is not the blocker I feared**: indexing is linear, and 1B tokens is queryable with the commodity
  operations Korpora needs. This removes the main reason for "not now" in the full-replacement discussion,
  but not the others (feature parity, format stability, single author).
- The blockers for word profiles are small and fixable upstream (API drops the `dcoll` relation, fd-per-file),
  and the author is a colleague.
- No cancellation and no subcorpus object remain design gaps for a full replacement; for a second engine
  they are acceptable (disable the feature per engine).
- Waiting for pando to mature is reasonable: the file format may change (each change means re-indexing
  large corpora), the API lags the CLI, and one test already fails. A sensible order is: report the two
  bugs upstream now, keep the spike scripts, and start Phase B (engine seam), which is useful regardless,
  while pando matures. Phase C/D after the author confirms format stability.

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
