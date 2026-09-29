# Phase 7 — Natural-language → CQL query assistant (plan)

Status: long-term research branch (`feat/nl-query-assistant`), ending in
a fine-tuned model (phase 6); it may pause for other goals between
phases. **Paused 2026-09-29 after phase 3** (generation in Swift at
parity with the Python harness). Resume at phase 4, which needs the
decisions under "Open decisions (phase 4)". Re-planned 2026-09-29 around an **optional, downloaded MLX model on
macOS 15+** (was: Apple's on-device model, macOS 27 only). Engine
primitives (7.1) and `QueryPlan`/`CQLSerializer` (7.2, part) are done and
unaffected. The build/size/release cost of MLX was measured the same day
(see "Cost of MLX", below), and the user judged it worth it (go,
2026-09-29). Linked from `docs/project-plan.md`, "Phase 7".

## Context

Users should be able to describe what they want ("adjective followed by a
noun, in fiction by Twain") and get a CQL query they can inspect, edit and
run.

The first plan (2026-09-28) was built on macOS 27's Foundation Models
framework with Apple's free on-device model as the no-download baseline.
That baseline never worked on the dev Mac: `fm available` keeps reporting
`modelNotReady`, whatever the Apple Intelligence settings. Czech-language
Macs are excluded from it anyway, because Apple Intelligence doesn't support
Czech. **Decision (user, 2026-09-29): drop Apple's model and make the
whole assistant optional, enabled by downloading an MLX model.**

Without Apple's model, macOS 27 only gives us API conveniences
(`@Generable`, `DynamicGenerationSchema`, `LanguageModelSession` and its
model-driven tool calling). That's not worth losing every user on macOS
15–26. The same engine is available without them:

- `ml-explore/mlx-swift-lm`'s **`MLXGuidedGeneration`** constrains any MLX
  model's output to a **JSON Schema or an EBNF grammar** by masking logits
  every step (vendored XGrammar, namespace-renamed). It is standalone, with
  "no FoundationModels coupling and no @available floor beyond the
  package's macOS 14 / iOS 17 minimum". The macOS 27 adapter
  (`MLXFoundationModels`) is a layer on top of this same engine, so we lose
  nothing by using it directly.
- `MLXLLM` has Qwen3 / Qwen3.5 / Gemma etc. `MLXLMCommon` loads a model
  from a local directory through small `Downloader`/`TokenizerLoader`
  protocols, so the download can be our own code.
- MLX needs Apple silicon. The Release build is already arm64-only, at
  macOS 15.

Evidence that still shapes the design (research 2026-09-28):
- NL→CQL is hard for LLMs without help: GPT-4 scored 24.5% execution
  accuracy zero-shot with docs vs 65.5% with 3 examples (Lu et al. 2024,
  arXiv 2402.13740); the CNK "AI Corpus Linguist" (Milička & Machálek 2026)
  is "barely usable" without reasoning. So accuracy comes from the pipeline
  (structure, corpus facts, examples, validation), not model size alone.
  The 2026-09-29 smoke test agrees: stock Qwen3-1.7B-4bit, zero-shot, no
  corpus facts, produced schema-valid but wrong plans (see "Cost of MLX").

Related (checked 2026-09-29): `honzas83/kontext-mcp` (Jan Švec, ZČU, MIT)
is a ~220-line MCP server wrapping LINDAT KonText's HTTP API (list
corpora, corpus details, search, freqs, colls, filter). It has **no
NL→CQL logic of its own**: a frontier model (Claude, Gemini, Codex) writes
the CQL, looks at `concsize` and the hits, and refines. There's nothing to
reuse in code. It does confirm the loop (corpus facts → query → check the
hits → refine) and adds an idea: feed back a frequency distribution of the
hits (e.g. top tags at the KWIC), not only the hit count. Its real value
for us is as a data path: LINDAT hosts the **EU DGT-UD** corpora (24
languages, `dgtud_cs` 100M tokens with `pos` = UPOS, `tag` = Czech
positional (2261 values), `feats`, `deprel`, `p_*` parent attributes).
These are the same engine, so a frontier model driving kontext-mcp can
generate and engine-verify Czech-positional and multilingual training data
and benchmark items (phase 6), and they test the generic path (`pos`, not
`upos`).

## Decisions

- (2026-09-28, still valid) The model fills a structured `QueryPlan`; the
  app serializes it to CQL. English requests + UD tagset first; Czech
  requests + the Czech positional tagset come with the fine-tuned model.
- (2026-09-29) **Fine-tuning is the planned end point, no longer
  conditional.** `feat/nl-query-assistant` is a long-term research
  branch: benchmark → prompt pipeline → app integration → fine-tuned
  model. Work on it may pause for other goals at any phase boundary, so
  each phase should end in a committed, documented state that can sit for
  a while (this file's status line + the phase's results section say
  where it stopped). The benchmark's job is to measure what fine-tuning
  buys, not to decide whether to do it.
- (2026-09-29) No Apple model tier. The assistant is **off until the user
  downloads a model** in Settings. Target: the app's own floor, macOS 15,
  Apple silicon. No `FoundationModels` import.
- (2026-09-29) Go on shipping MLX inside the app, after reviewing "Cost of
  MLX" below.

## Design

### 1. Structured output, not free text
The model fills a `QueryPlan` (`Korpora/Korpora/Assistant/QueryPlan.swift`,
done), constrained by a **JSON Schema generated at runtime per corpus**:
`attribute` is an `enum` of the corpus's real attribute names, structure
names/attributes are `enum`s of the real ones, `op` is `enum ["=","!="]`,
arrays carry `minItems`/`maxItems`, and strings carry `maxLength`. Values
are strings (a Czech positional tagset has ~4k values, too many to
enumerate). `CQLSerializer` (done, tested) escapes values and emits
`[tag="A.*"][tag="N.*"] within <doc author="twain"/>`. This is deliberately
a subset of CQL (no meet/union/containing in v1), and the user can still
edit the result by hand.

EBNF could instead constrain the model directly to CQL text. We're staying
with JSON: the serializer already owns quoting, and QueryPlan JSON is the
simpler fine-tuning target.

Generation uses `QueryGrammar`, a compact EBNF of the same language, not
the JSON Schema, and runs **without jump-forward** (see "Phase 3
results"). It keeps `ClosingTokenBias` and turns off the model's thinking
mode (Qwen3: `additionalContext: ["enable_thinking": false]`). The JSON
Schema (`QuerySchema`) is still what the Python harness constrains with.

### 2. Corpus facts in the prompt
`QueryContextBuilder` assembles, within a token budget measured with the
model's tokenizer:
- compact CQL reference for the subset (~400 tokens, bundled resource);
- attribute + structure names (existing `Corpus.info()`);
- tagset evidence: the 40 most frequent values of the tag-like attribute
  (`Corpus.topAttributeValues`, done) and the registry's `TAGSETDOC` /
  `LABEL` if present (`Corpus.registryValue`, done);
- 3–5 few-shot examples retrieved from a bundled example bank for the
  detected tagset family, chosen by simple keyword overlap with the
  request. Detection: an attribute named `upos`/`feats` → UD; sampled tag
  values matching the 15-char positional pattern → Czech positional; else
  generic.

### 3. Validation loop (app-driven, no model tool calls)
Instead of letting the model call tools, the app runs a fixed loop:
generate → decode `QueryPlan` → serialize → `Corpus.probeQuery` (done;
validates and counts hits up to a cap). On an engine error, or when a
condition's value doesn't exist (checked with the existing
`Corpus.attributeValues(attribute:matching:…)`), re-prompt **once** with
the error or the nearest existing values. A 2B-class model follows a fixed
loop more reliably than it chooses tool calls. The result is **inserted
into the query field for review, never auto-run**, together with the
model's one-line explanation and the capped hit count.

### 4. Model management
- Settings gets an "Assistant" pane (`SettingsWindowController.Pane`).
  With no model installed it shows the assistant as off, the download size
  and a Download button. Once installed, it shows the model name and size
  on disk, plus Delete.
- Download: our own `Downloader`-free code (the directory-loading API
  doesn't need one) fetching a pinned file list with URLSession, SHA-256
  pinned, into Application Support/Korpora/Models/<name> (visible in
  Finder), with progress and resume. Source: the model's Hugging Face repo
  at a pinned revision for a stock model; a GitHub release asset or our own
  HF repo for a fine-tuned one.
- Tokenizer: `swift-transformers`' `Tokenizers` (`AutoTokenizer.from(
  modelFolder:)`) behind a ~30-line `MLXLMCommon.Tokenizer` adapter (a
  hand-written copy of what `MLXHuggingFace`'s `#adaptHuggingFaceTokenizer`
  macro expands to). We deliberately don't link `MLXHuggingFace`:
  it pulls in a swift-syntax macro plugin, which Xcode would ask to trust
  and `xcodebuild` would need `-skipMacroValidation` for.
- Loading and generation run off the main actor (the first grammar compile
  blocks for hundreds of ms). The model is loaded on first use and unloaded
  under memory pressure / after idle.

### 5. UI
A "Describe…" button (sparkles symbol) beside the query field in the New
Concordance sheet (`NewConcordanceSheetController`) and the document query
bar (`ConcordanceViewController`) opens a small popover: text field +
Generate, then shows the generated CQL (syntax-colored via
`CQLQueryField.syntaxColoredAttributedString`), explanation, hit count and
"Use Query". Without a model installed the button is hidden (or opens the
Settings pane — decide in phase 4).

## Cost of MLX (measured 2026-09-29)

This is a throwaway worktree of `e9d9548` with `mlx-swift-lm` pinned to
`c043fb3` (main, 2026-09-28) linking `MLXLLM` + `MLXLMCommon` +
`MLXGuidedGeneration`, plus `swift-transformers` 1.3.4 (`Tokenizers`) and
~100 lines of spike code: load a local model, run one JSON-Schema-guided
generation. It was built with the Release config and the real release
deps, signed with Developer ID, and run on the M3 Ultra.

| | today (v0.1) | + MLX | + MLX, stripped |
|---|---|---|---|
| Korpora.app | 4.5 MB | 48 MB | 26 MB |
| main executable | 2.8 MB | 43 MB | 22 MB |
| DMG (UDZO) | 1.7 MB | 13.5 MB | 10.4 MB |
| clean Release build | 15 s | 102 s | — |
| build warnings | 16 | 92 (+76 from mlx-swift's `Cmlx` C++) | — |

- **Where the size goes:** almost all of it is compiled code in the
  executable (MLX core C++, XGrammar, swift-transformers + swift-jinja +
  swift-crypto). The Metal library (`mlx-swift_Cmlx.bundle/…/
  default.metallib`) is only 2.4 MB. Resource bundles added:
  `mlx-swift_Cmlx`, `swift-transformers_Hub`, `swift-crypto_Crypto`, and
  `Frameworks/libswiftCompatibilitySpan.dylib` (Swift back-deployment
  for macOS 15).
- **Stripping:** Release doesn't strip today (it only happens with
  `DEPLOYMENT_POSTPROCESSING=YES`, i.e. on `archive`). Building with
  `DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES` saves 20 MB,
  still verifies and still runs. If MLX goes in, set this in project.yml's
  Release config.
- **Model download (separate, only for users who enable the assistant):**
  ~1.0 GB for Qwen3-1.7B-4bit, ~1.3 GB for Qwen3.5-2B-4bit. RAM while
  loaded is about the same.

What changes in building and releasing:
1. **Metal Toolchain.** Xcode 27 doesn't ship the Metal compiler; the first
   build fails with "cannot execute tool 'metal' due to missing Metal
   Toolchain". One-time fix per machine: `xcodebuild -downloadComponent
   MetalToolchain` (839 MB). Belongs in `scripts/setup-dev-machine.sh` and
   in `make-release.sh`'s preconditions.
2. **Package dependencies.** From none to 12 resolved packages
   (mlx-swift-lm, mlx-swift, swift-transformers, swift-jinja,
   swift-huggingface, swift-crypto, swift-asn1, swift-collections,
   swift-numerics, swift-syntax, EventSource, yyjson; ~480 MB of checkouts,
   mlx-swift alone 119 MB). The first build of a fresh clone needs network.
   swift-syntax is resolved but not built (only `MLXHuggingFace`'s macros
   need it, and we don't link that). Pin mlx-swift-lm to a commit:
   `MLXGuidedGeneration` isn't in any tagged release yet (latest tag
   3.31.4, 2026-06-29, predates it).
3. **Signing / notarization: no change needed.** Xcode signs the new
   bundles and the Span dylib itself, `codesign --verify --deep --strict`
   passes, and a notarization test submission of the stripped app
   (`841eb8f4-dbc6-4190-89f9-fa7e5709027c`) came back **Accepted with no
   issues**. No new entitlements: MLX's runtime Metal kernel compilation
   works under hardened runtime, as the run below shows.
4. **Tests.** Unchanged: ManateeKit doesn't get MLX, so `swift test` still
   works standalone. The assistant code lives in the app target and its
   tests run under `xcodebuild test` / Xcode, where Metal shaders compile.
   Model-dependent tests must skip when no model is present (CI has none).
5. **`make-release.sh`:** add the Metal Toolchain precondition, add the new
   binaries to the signature-check loop (`Frameworks/*.dylib`), and switch
   on stripping. Nothing else changes.

Smoke test (stock `mlx-community/Qwen3-1.7B-4bit`, zero-shot, no corpus
facts/examples, from the signed hardened-runtime Release app): model load
0.4 s (warm file cache), generation 1.9–3.0 s, schema-valid JSON. The plan
itself was wrong (it put `dog` into `word`, `lemma` *and* `feats` of a
single position and dropped the adjective), which is what the
evidence above predicts without examples and corpus facts. Accuracy is the
job of the phase 0 spike, not this measurement.

## Phase 0 results (2026-09-29)

Harness: `scripts/nl-spike/run.py` (mlx-lm + XGrammar, the engine
`MLXGuidedGeneration` vendors; compact JSON, greedy decoding, thinking
off) on UD English EWT. Two sets of 20 English requests with gold CQL:
`requests.tsv` (dev: prompts were written against it) and `heldout.tsv`
(written afterwards, never used for prompt changes). A gold may list
acceptable alternatives after ` || ` (other reasonable readings, e.g.
`word!=` where the gold has `lemma!=`). Scores compare the total hit count
plus the first five hit positions (a proxy for hit-set equality).
Per-request times are on the M3 Ultra.

Acceptable / 20, stock 4-bit models:

| model (weights) | v1 dev | v1 held-out | v2+retry dev | v2+retry held-out | s/request |
|---|---|---|---|---|---|
| Qwen3-1.7B (1.0 GB) | 5 | — | — | — | 0.5 |
| Qwen3.5-2B (1.7 GB) | 6 | — | — | — | 0.6 |
| Qwen3-4B (2.3 GB) | 13 | 15 | 12 | 11 | 1.0–1.3 |
| Gemma 4 E4B (5.2 GB) | 14 | 12 | 15 | 10 | 1.1–1.5 |
| Qwen3-8B (4.6 GB) | 15 | 13 | 15 | 13 | 1.4–2.0 |

- **v1** is `instructions.txt`: hand-written corpus notes with glosses
  ("ADP (preposition)", "Degree=Cmp (comparative)") and a curated feats
  list, plus 5 examples. **v2** is `instructions-v2.txt`: the corpus
  section generated from frequency lists, as `QueryContextBuilder` would
  build it (all 64 feats values, top deprel/xpos, without glosses), 3
  added rules (one token per position, regex anchoring, only listed
  values), 2 more examples, and one validation retry (a nonexistent value
  or zero hits is fed back to the model).
- **Findings:**
  1. The 2B class is unusable without fine-tuning. 4–8B stock models get
     roughly 55–75% acceptable, with 1–2 s per request. They're usable as a
     starting point, but not reliable.
  2. v2 did **not** help: flat on dev, worse on held-out. Glosses seem to
     matter more than completeness: with raw lists the models pick
     plausible-looking wrong values (`PronType=Art` for possessives, `ADP`
     for infinitival "to"). So bundle a **UD gloss table** (UD is universal,
     so it's a static resource) and put glossed values in the prompt; raw
     frequency lists are for unknown tagsets only.
  3. The retry fixed only a few cases: the model tends to swap one wrong
     value for another. Keep it (it's cheap and catches invented values),
     but don't count on it.
  4. The remaining errors are systematic: token order and position
     structure ("the preposition of between two nouns" → `[of][N][N]`, `[]?`
     for "any word"), and UD conventions (relative clause → `acl:relcl`,
     "to" + infinitive is `PART`). These are the kind of errors
     fine-tuning on engine-verified QueryPlans (phase 6) targets. Few-shot
     retrieval from a larger example bank is the cheaper thing to try
     first.
  5. 20 requests per set is noisy (one request = 5 points); results within
     ±2 aren't differences. The benchmark needs ≥100 before phase 5
     compares anything.
- **Go/no-go: go, with caveats.** Build the app pipeline (everything in
  phases 2–4 is model-independent and needed for a fine-tuned model too)
  with **Qwen3-4B-4bit** as the stock default: 2.3 GB, the best held-out
  score under 5 GB, Apache-2.0. Expect phase 6 fine-tuning to be needed
  for a good product rather than optional.

## Phase 2 results (2026-09-29)

The model-independent half lives in a local package, **`KorporaAssistant/`**
(next to `ManateeKit`, linked into the app via project.yml). It tests with
plain `swift test`, and its dev CLI `korpora-assistant` prints the profile,
schema and exact prompts for a corpus, so `scripts/nl-spike/run.py
--prompts/--schema` benchmarks the app's own prompt builder.
- `QueryPlan`, `CQLSerializer` (moved from the app target).
- `QuerySchema`: per-corpus JSON Schema, keys in generation order.
  Attribute and structure-attribute names are `enum`s, and `within` is
  pinned empty for a corpus without structure attributes.
- `CorpusProfile`: gathers per-attribute value samples
  (`topAttributeValues`; for MULTIVALUE attributes the lexicon's
  combinations are dropped, since it holds single values *and*
  combinations), structure-attribute values, and registry LABELs. It
  detects each attribute's **role from its values**, not its name: UD POS
  (`upos` in EWT, `pos` in DGT-UD), UD features, UD relations, Czech
  positional tag, word, lemma, other. Categorical structure attributes
  (genre) are told apart from identifiers (`doc.id`).
- `QueryRepair` (added with the benchmark): unambiguous case/plural fixes
  of values against fully sampled value lists.
- `QueryContextBuilder`: rules, then corpus facts (UD values glossed from
  `Resources/TagsetGlosses.json`; Czech positional slots explained;
  `p_*`/`ep_*` parent copies named as such), then examples from
  `Resources/ExampleBank.json`. The bank is written against role
  placeholders (`{udPOS}`, `{category}`) and filled with the corpus's own
  names; examples a corpus can't express are skipped. Retrieval is by
  keyword overlap, and a token budget steps down through four detail
  levels.
- 28 package tests; the app suite is 90 (the 8 serializer tests moved to
  the package).

Benchmark of the Swift-built prompt (no retry), acceptable / 20:

| | dev | held-out |
|---|---|---|
| Qwen3-4B, app prompt | 12 | 10 |
| Qwen3-4B, v1 (hand-written) | 13 | 15 |
| Qwen3-8B, app prompt | 13 | 13 |
| Qwen3-8B, v1 | 15 | 13 |

Ablation on dev only (Qwen3-4B, acceptable / 20): full detail + retrieval
12; full, fixed examples 10; level 2 (shorter lists, 3 examples) 9 / 7;
level 3 at 7. So **more corpus detail helps**, and retrieval helps a
little. The hand-written v1's held-out lead isn't explained by length; with
20 items per set it may be partly noise. New failure types with the app
prompt: pluralized structure values (`genre="weblogs"`), relation names put
in the POS attribute (`upos="OBJ"`), and retrieval copying an example's
structure ("proper nouns in the plural" picked "a sequence of proper
nouns" and added `+`).

**Held-out hygiene:** the held-out failures above were read during this
work, so `heldout.tsv` is now contaminated. The ≥100 benchmark needs a
fresh held-out split that nobody reads before the final comparison.

## Benchmark (2026-09-29)

`scripts/nl-spike/bench/` holds the benchmark. So far it has one corpus,
UD English EWT.
- `ud-en-ewt-dev.tsv` (60) is for any prompt or pipeline work. It holds
  the phase 0 sets (`requests.tsv`, and `heldout.tsv`, whose failures were
  read in phase 2) plus 20 new requests.
- `ud-en-ewt-test.tsv` (60 new) is **not to be used for tuning**. Run it
  only for a milestone comparison (the phase 5 baseline, a fine-tuned
  model), and don't change prompts because of what it shows. Once its
  failures have been read, it needs replacing like `heldout.tsv` did.

Gold queries may list acceptable alternatives after ` || `. Every gold
query and alternative was checked to parse and find hits. `run.py`
reports a per-category breakdown read off the gold (pos, feats, deprel,
lemma, word, regex, alt, neg, seq, gap, rep, within).
`scripts/nl-spike/bench-dev.sh TAG [MODEL...]` runs the dev split through
the app's own code: prompt builder and schema (`korpora-assistant
prompts/schema`) plus repair and serializer (`korpora-assistant plans`,
via `run.py --app-cli`). `FLAGS` selects prompt variants.

Still to come: a second corpus with different attribute names (a DGT-UD
corpus from LINDAT, or a local UD treebank with `pos` for UPOS), Czech
positional requests for phase 6, and more gap/alt/rep items (1–3 each so
far).

### Dev-split results, acceptable / 60 (no retry)

Columns are subsets of the dev split: orig = `requests.tsv`, held =
`heldout.tsv`, new = the 20 added in the benchmark.

| prompt | Qwen3-4B | orig / held / new | Qwen3-8B |
|---|---|---|---|
| v1 (phase 0, hand-written for EWT) | 41 | 13 / 15 / 13 | 40 |
| app, phase 2 | 34 | 12 / 10 / 12 | 38 |
| + features grouped, "copy values exactly" rule, 3 fixed examples | 31 | | 42 |
| + xpos as secondary tagset, value repair (**current default**) | 34 | 12 / 10 / 12 | 42 |
| default, curated UD lists (gloss-table order) | 34 | | 34 |
| curated, v1 rules | 30 | | |
| uncurated, v1 rules | 28 | | |
| curated, detail level 2 / 3 | 24 / 23 | | |
| curated, fixed examples only | 31 | | |
| no feature/relation glosses | 32 | | 39 |
| v1 text with the app's schema + serializer | 41 | | |

- Qwen3-8B with the default app prompt beats v1 (42 vs 40). For Qwen3-4B
  the app prompt ties v1 on the 20 new requests, and all of v1's lead is on
  the held-20 subset: position-order and condition-splitting errors
  (`[of][N][N]`, `[PRON][deprel=obj]`). That's a 4B weakness around
  structure that the prompt only partly fixes. It's a fine-tuning target.
- The phase 2 rules help (34 vs 30). Glosses help slightly. Less detail
  hurts a lot, especially features. Curating UD lists is neutral for the
  4B and bad for the 8B (34 vs 42), so it's off by default. The schema
  doesn't matter (v1 scores the same with the app's).
- Value repair (`QueryRepair`: an unambiguous case or plural fix against
  a fully sampled value list) fired on 2 of 60 plans for the 4B, 0 for the
  8B.
- With 60 items one standard error is about ±4. Differences under ~6 are
  not reliable.

## Phase 3 results (2026-09-29)

**`KorporaGeneration/`** is a second local package (macOS 14). It depends
on KorporaAssistant, ManateeKit, `mlx-swift-lm` pinned to `c043fb3`
(`MLXLLM`, `MLXLMCommon`, `MLXGuidedGeneration`) and `swift-transformers`
(`Tokenizers`). It has to be built with xcodebuild, because MLX's Metal
shaders don't build under plain SwiftPM; KorporaAssistant stays
`swift test`.
- `LocalModel`: loads an MLX model from a local snapshot directory. It
  adapts swift-transformers' tokenizer by hand, with no MLXHuggingFace
  macros. `generate(grammar:messages:)` does greedy, EBNF-constrained
  decoding with thinking off.
- `QueryAssistant.suggest(_:)`: prompt (token budget measured with the
  model's tokenizer), generation, decode to `QueryPlan`, `QueryRepair`,
  `CQLSerializer`, then `Corpus.probeQuery` (hits capped at 10k). One
  retry with `QueryFeedback` when the engine rejects the query, a plain
  `=` value doesn't exist, or nothing matches. The existence check uses
  the sample, or the engine for values outside a partial sample. The
  feedback names the attribute a misplaced value belongs to
  (`feats="aux:pass"` → "a value of deprel").
- `QueryGrammar` (in KorporaAssistant): the QueryPlan as compact EBNF.
- CLI `korpora-generate ask|bench` and `scripts/nl-spike/bench-swift.sh`
  (dev split through the Swift path, scored by `run.py --rescore`).

Two generation bugs found on the way, both invisible in the prompt text:
1. **Free whitespace.** The JSON Schema path in mlx-swift-lm compiles
   with XGrammar's defaults (`any_whitespace=true`); the C shim doesn't
   expose the option. Even with `WhitespaceTokenBias`, Qwen3-4B emitted a
   run of newlines inside the first key and produced a wrong query.
   Fixed with our own compact EBNF (`QueryGrammar`), which also allows
   escaped `\\`/`\"` in values; XGrammar's `maxLength` strings forbid
   backslashes, so a regex like `\?` couldn't be written.
2. **Jump-forward** (`GrammarConstraint(fastForward: true)`) corrupted
   generation: XGrammar inserts the grammar's forced text as tokens of its
   own choosing, not the model's. With it on, the Swift path scored
   **15/60** against Python's 34 with a token-identical prompt (checked
   ids). It's off now (`KORPORA_FF=1` re-enables it). Worth reporting
   upstream with a reproducer.

Dev split, acceptable / 60, Swift path (Release build, M3 Ultra):

| | Qwen3-4B | Qwen3-8B |
|---|---|---|
| Python harness, same prompt (bench-dev.sh) | 34 | 42 |
| Swift, jump-forward on | 14–15 | |
| Swift, compact / spaced JSON, no retry | 33 / 32 | |
| Swift, compact, retry | 33 (8 retried) | 43 (6 retried) |
| + "value of another attribute" feedback | 34 (8 retried) | |

The Swift path matches Python within noise. Per request it takes 2.2–2.6 s
(4B) and 3.3 s (8B), slower than Python's 1.3 / 2.1 s, which is worth
profiling later (grammar mask per token without jump-forward, or the
Debug-only diagnostics). The retry rarely changes the outcome: the model
tends to repeat itself or swap one wrong value for another. Debug builds
are about 15x slower (unoptimized MLX/XGrammar C++): always benchmark
Release.

## Open decisions (phase 4)

Asked 2026-09-29, not answered yet:
1. **Default model:** Qwen3-4B-4bit (2.3 GB, 34/60 on dev) or Qwen3-8B-4bit
   (4.6 GB, 42–43/60), or offer both.
2. **Download source:** the `mlx-community` Hugging Face repos at a pinned
   revision, or our own copy as a GitHub release asset (SHA-256 pinned
   either way).
3. **No model installed:** hide the "Describe…" button, or show it and
   have it lead to the Settings "Assistant" pane.

Also open, not blocking: Swift generation is slower than Python (2.2–2.6 s
vs 1.3 s per request for the 4B), and the retry rarely helps.

## Resuming

- Python harness: `data/.venv-nl` (gitignored; recreate per `run.py`'s
  header). Models are in the Hugging Face cache (on the dev Mac
  `HF_HUB_CACHE=/Volumes/STORAGE/HF_Hub_Cache`).
- `KorporaAssistant`: `swift build && swift test` (40 tests).
- `KorporaGeneration`: xcodebuild Release (see `bench-swift.sh`'s header).
  It needs the Metal Toolchain component (`xcodebuild -downloadComponent
  MetalToolchain`), installed on the dev Mac 2026-09-29.
- Corpora: UD English EWT at `data/ud-en-ewt/` (compiled, registry in
  `data/ud-en-ewt/registry`); SYN2025 in the app's compiled corpora.
- Dev loop: `scripts/nl-spike/bench-dev.sh` (Python, prompt variants) and
  `bench-swift.sh` (the app's Swift path). The test split
  (`bench/ud-en-ewt-test.tsv`) is still unread; keep it that way until a
  milestone comparison.

## Phases
0. ~~**Feasibility spike (dev-only, no app UI).**~~ — done, see "Phase 0
   results": go, default Qwen3-4B-4bit. Run ~20 English requests against a UD-annotated
   corpus (UD English converted with `scripts/conllu2vert.py`) through the
   real prompt (corpus facts + examples) and schema, with stock
   Qwen3.5-2B-4bit and Qwen3-4B-4bit. Score by hand: valid? same hits as
   the intended query? **Go/no-go:** if a stock ≤4B model is clearly
   unusable even with structure + examples, the assistant needs
   fine-tuning from the start (phase 6 becomes mandatory) or is shelved.
1. ~~Engine additions + tests~~ — done (7.1).
2. ~~`QueryPlan`, `CQLSerializer`, `QuerySchema`, `CorpusProfile`,
   `QueryContextBuilder`, glosses, UD example bank~~ — done, see "Phase 2
   results". ~~Benchmark: 60 dev + 60 untouched test on UD English EWT~~ —
   done, see "Benchmark". Still open: a second corpus (other attribute
   names), more gap/alt/rep items.
3. ~~`QueryAssistant`: model loading, guided generation, decode,
   repair, validation/retry loop; Swift benchmark path~~ — done, see
   "Phase 3 results". Open: speed (2.2 s vs Python's 1.3 s for the 4B),
   and a better retry (it rarely helps yet).
4. UI (popover, both entry points) + Settings "Assistant" pane with model
   download/delete; the project.yml/`make-release.sh` changes from "Cost of
   MLX".
5. **Baseline for fine-tuning:** benchmark results across stock models,
   sizes and prompt variants, on the untouched held-out split. That's
   the number fine-tuning has to beat. It also picks the base model and
   the smallest size worth tuning.
6. Fine-tuned model (the branch's end goal), adding Czech requests + the
   Czech positional tagset:
   - Training data, generated dev-side, never shipped: sample valid
     QueryPlans from templates over real UD and Czech positional corpora,
     keep those with non-empty hits (engine-verified), back-translate each
     to several English and Czech requests with a large LLM, human-review a
     sample. (Same idea as Mikušek's 2026 MUNI thesis on Sketch Engine
     query logs.)
   - LoRA fine-tune with `mlx-lm` (Python, dev machine) on a small base
     model (Qwen3.5-2B, Apache-2.0), merge, quantize to 4-bit (~1.3 GB).
   - Ships through the same download path as a stock model; adds the
     `czech-positional` example bank.

## Critical files
- `KorporaAssistant/` (Swift package, macOS 14+, depends on ManateeKit):
  `Sources/KorporaAssistant/` — `QueryPlan.swift`, `CQLSerializer.swift`,
  `QuerySchema.swift`, `CorpusProfile.swift`, `QueryContextBuilder.swift`,
  `Resources/{TagsetGlosses,ExampleBank}.json`; later `QueryAssistant.swift`
  (loading, generation, retry) and `ModelStore.swift` (download/verify/
  delete). `Sources/korpora-assistant/` is the dev CLI. Also
  `QueryRepair.swift`, `QueryFeedback.swift`, `QueryGrammar.swift`.
- `KorporaGeneration/` (Swift package, xcodebuild only): `LocalModel.swift`,
  `QueryAssistant.swift`, CLI `korpora-generate`.
- App (`Korpora/Korpora/`): `DescribeQueryPopoverController.swift`,
  `AssistantSettingsViewController.swift`; modified
  `Views/CQLQueryField.swift`, `Controllers/NewConcordanceSheetController.swift`,
  `Controllers/ConcordanceViewController.swift`,
  `Settings/SettingsWindowController.swift`, `Settings/AppSettings.swift`.
- `Korpora/project.yml` (packages: `KorporaAssistant` (done); later
  `mlx-swift-lm` pinned by revision → `MLXLLM`, `MLXLMCommon`,
  `MLXGuidedGeneration`, and `swift-transformers` → `Tokenizers`, either
  here or in `KorporaAssistant`; Release stripping), `scripts/make-release.sh`,
  `scripts/setup-dev-machine.sh`.
- `scripts/nl-spike/` — benchmark harness (Python, dev-only).

## Verification
- Unit: serializer round-trips (done), schema builder, context budget
  never exceeds the model's context, bridge fns (done).
- Benchmark: see phase 3; the acceptance bar is set after the spike.
- Manual: Xcode click-through (both entry points; no-model state;
  download, cancel, resume, delete); Release build signs + notarizes
  (`scripts/make-release.sh`); in the macOS 15 VM
  (`scripts/release-smoke-vm.sh`) the app launches, downloads a model and
  generates a query. MLX in a VM without a GPU is untested, and needs
  checking before relying on the VM for this.
