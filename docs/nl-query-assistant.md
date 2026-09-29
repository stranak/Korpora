# Phase 7 — Natural-language → CQL query assistant (plan)

Status: re-planned 2026-09-29 around an **optional, downloaded MLX model on
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
  requests + the Czech positional tagset come with a fine-tuned model,
  only if the benchmark shows fine-tuning pays off.
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

Generation must pass `WhitespaceTokenBias` and `ClosingTokenBias` (both in
`MLXGuidedGeneration`) and turn off the model's thinking mode (Qwen3:
`additionalContext: ["enable_thinking": false]`). Without the biases the
smoke test's model emitted whitespace forever between JSON tokens, which
JSON grammar permits. `MLXFoundationModels` applies both internally.

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
2. `QueryPlan` + `CQLSerializer` — done. Remaining: runtime JSON Schema
   builder from a corpus's `info()`, `QueryContextBuilder`, example banks.
   Everything is unit-tested without a model.
3. `QueryAssistant`: model loading, guided generation (with the biases
   above), decode, validation/retry loop. A benchmark harness: ≥100 English
   NL→CQL pairs on a UD corpus, scored by execution accuracy (same hit set
   as the gold query). It runs from a test target, skipped without a local
   model.
4. UI (popover, both entry points) + Settings "Assistant" pane with model
   download/delete; the project.yml/`make-release.sh` changes from "Cost of
   MLX".
5. **Decision point:** does fine-tuning buy enough? Compare benchmark
   results across stock models and sizes.
6. (If 5 says yes) fine-tuned model, adding Czech requests + the Czech
   positional tagset:
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
- New: `Korpora/Korpora/Assistant/` — `QueryPlan.swift`,
  `CQLSerializer.swift` (both done), `QuerySchema.swift` (runtime JSON
  Schema), `QueryContextBuilder.swift`, `QueryAssistant.swift` (loading,
  generation, retry), `ModelStore.swift` (download/verify/delete),
  `DescribeQueryPopoverController.swift`,
  `AssistantSettingsViewController.swift`; resources `CQLReference.md`,
  `Examples/{ud,generic}.json`.
- Modified: `Korpora/project.yml` (packages: `mlx-swift-lm` pinned by
  revision → `MLXLLM`, `MLXLMCommon`, `MLXGuidedGeneration`;
  `swift-transformers` → `Tokenizers`; Release stripping),
  `Views/CQLQueryField.swift`, `Controllers/NewConcordanceSheetController.swift`,
  `Controllers/ConcordanceViewController.swift`,
  `Settings/SettingsWindowController.swift`, `Settings/AppSettings.swift`,
  `scripts/make-release.sh`, `scripts/setup-dev-machine.sh`.

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
