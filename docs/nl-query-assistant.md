# Phase 7 — Natural-language → CQL query assistant (plan)

Status: planned 2026-09-28; phase 0 (feasibility spike) pending. Linked from
`docs/project-plan.md`, "Phase 7".

## Context

Users should be able to describe what they want ("adjective followed by a
noun, in fiction by Twain") and get a CQL query they can inspect, edit and
run. The user wants a local solution first and accepts **requiring macOS 27
for this feature** (the app itself stays at macOS 15) if that substantially
simplifies it. It does: macOS 27's Foundation Models framework gives one
Swift API (`LanguageModelSession`) over Apple's free on-device model *and*
over pluggable local models (MLX), with guided generation and tool calling —
no llama.cpp, no C grammar plumbing, and no model download at all for users
whose Mac has Apple Intelligence.

Evidence that shapes the design (research 2026-09-28):
- NL→CQL is hard for LLMs without help: GPT-4 scored 24.5% execution
  accuracy zero-shot with docs vs 65.5% with 3 examples (Lu et al. 2024,
  arXiv 2402.13740); the CNK "AI Corpus Linguist" (Milička & Machálek 2026)
  is "barely usable" without reasoning. So accuracy comes from the pipeline
  (structure, corpus facts, examples, validation), not model size alone.
- Apple on-device model on macOS 27: `SystemLanguageModel` (AFM 3 Core 3B,
  or Core Advanced 20B-sparse on high-end Macs, system-chosen, readable via
  `.variant`); context 4096 (Core) / 8192 (Advanced) — read `contextSize`
  at runtime. Guided generation: `@Generable`, `.anyOf`, `.pattern(Regex)`,
  runtime `DynamicGenerationSchema` (anyOf + recursion). **No arbitrary
  grammar.** Tool calling with `toolCallingMode`. No entitlement needed for
  Developer-ID apps. Custom LoRA adapters are **obsoleted in 27** — no
  fine-tuning of Apple's model.
- Availability gaps: needs Apple Intelligence on; Czech is not a supported
  Apple Intelligence language (a Czech-language Mac likely reports
  unavailable). Fallback: `MLXLanguageModel` from `ml-explore/mlx-swift-lm`
  (`MLXFoundationModels`, macOS 27 SDK) behind the same `LanguageModel`
  protocol — e.g. Qwen3.5-2B 4-bit (~1.3 GB, Apache-2.0), downloaded on
  demand.

## Decisions (user, 2026-09-28)
Two tiers:
- **Baseline (no download): Apple's on-device model, English requests,
  UD tagset** (curated example bank). Any other tagset (Penn, DevCorpus, …)
  uses the generic path: sampled top tag values, no curated bank. Macs
  without Apple's model get a clear "turn on Apple Intelligence" message
  with the concrete `UnavailableReason`.
- **Optional download: a fine-tuned MLX model** that adds **Czech requests
  + the Czech positional tagset** (the two go together in practice) and
  should raise quality generally. It also covers Macs where Apple's model
  is unavailable, incl. Czech-language setups. Built only if the benchmark
  shows fine-tuning makes a real difference — Apple's own model can't be
  fine-tuned on macOS 27 (adapters obsoleted), so an MLX model is the only
  fine-tuning route.

## Design

### 1. Structured output, not free text
The model fills a `@Generable` query object; the app serializes it to CQL.
Syntax errors become impossible by construction and every field is
constrainable:

```swift
@Generable struct QueryPlan {
  var positions: [Position]      // [.count 1...8]
  var within: [StructureFilter]  // e.g. doc.author="twain"
  var explanation: String        // one sentence, shown to the user
}
@Generable struct Position { var conditions: [Condition]; var repeat: Repeat? }  // [] = any token
@Generable struct Condition { var attribute: String; var op: Op; var value: String }  // op: = != 
```
Built at runtime as a `DynamicGenerationSchema` so `attribute` is
`.anyOf(corpus attribute names)` and structure names/attributes are
`.anyOf(real ones)`. Values are regex-guided, not enumerated (a Czech
positional tagset has ~4k values). `CQLSerializer` (pure, unit-tested)
escapes values and emits `[tag="A.*"][tag="N.*"] within <doc author="twain"/>`.
Deliberately a subset of CQL (no meet/union/containing in v1); the user can
still edit the result by hand.

### 2. Corpus facts in the prompt
`QueryContextBuilder` assembles, within `contextSize` (measured with
`tokenCount(for:)`):
- compact CQL reference for the subset (~400 tokens, bundled resource);
- attribute + structure names (existing `Corpus.info()`);
- tagset evidence: the 40 most frequent values of the tag-like attribute
  (new bridge fn, below) and the registry's `TAGSETDOC`/`LABEL` if present;
- 3–5 few-shot examples retrieved from a bundled example bank for the
  detected tagset family, chosen by simple keyword overlap with the
  request. Baseline ships the UD and generic banks (English requests).
  Detection: an attribute named `upos`/`feats` → UD; sampled tag values
  matching the 15-char positional pattern → Czech positional (baseline
  treats it as generic and suggests the optional model); else generic.

### 3. Tools + validation loop
Two `Tool`s the model may call: `lookupValues(attribute, pattern)` (wraps
existing `Corpus.attributeValues(attribute:matching:ignoreCase:limit:)`) so
it can check that "lemma=pes" exists, and `validateQuery(cql)` (new
parse-only bridge fn). After generation the app always validates; on an
engine error it re-prompts once with the error message. The result is
**inserted into the query field for review, never auto-run**, with the
model's one-line explanation and a capped hit count.

### 4. Backend selection
One pipeline, built against the macOS 27 `LanguageModel` protocol, with
two backends: the downloaded fine-tuned MLX model when present (preferred:
it's the better and Czech-capable one), else `SystemLanguageModel.default`
when `.available`. Otherwise the popover explains why
(`.appleIntelligenceNotEnabled` / `.deviceNotEligible` / `.modelNotReady`,
plus "Apple Intelligence doesn't support Czech as the system language" when
the device language is Czech) and offers the optional download once it
exists. All behind `if #available(macOS 27, *)`; on 15–26 the entry point
is hidden. The same `QueryPlan` schema is the output for both backends, so
the fine-tuning target is QueryPlan JSON, not raw CQL.

### 5. UI
A "Describe…" button (sparkles symbol) beside the query field in the New
Concordance sheet (`NewConcordanceSheetController`) and the document query
bar (`ConcordanceViewController`) opens a small popover: text field + Generate
→ shows the generated CQL (syntax-colored via
`CQLQueryField.syntaxColoredAttributedString`), explanation, hit count,
"Use Query". Settings gets an "Assistant" pane (`SettingsWindowController.Pane`)
with backend status, model download/delete.

## Engine additions (ManateeKit / CManatee)
- `mtc_query_validate(corp, cql, &error)` — `eval_cqpquery` then delete the
  RangeStream without building a Concordance; errors carry "near position N".
  Serialize through the `Corpus` actor (parser uses static globals).
- `mtc_attr_top_values(corp, attr, n, …)` — loop `id_range()`, `freq(id)`
  (`corp/posattr.hh:85`), return top N `(value, freq)`.
- `mtc_corpus_get_conf(corp, path, &error)` — wraps `Corpus::get_conf`
  (`corp/corpus.hh:66`) for TAGSETDOC / `tag.LABEL`; catch
  `CorpInfoNotFound`.
Swift wrappers on `Corpus` in `ManateeKit/Sources/ManateeKit/ManateeKit.swift`,
following the 6.7 `attributeValues` style.

## Critical files
- New: `Korpora/Korpora/Assistant/` — `QueryPlan.swift` (schema),
  `CQLSerializer.swift`, `QueryContextBuilder.swift`, `QueryAssistant.swift`
  (session, tools, retry), `AssistantBackend.swift`,
  `DescribeQueryPopoverController.swift`, `AssistantSettingsViewController.swift`;
  resources `CQLReference.md`, `Examples/{ud,generic}.json`
  (`czech-positional` bank ships with the optional model tier).
- Modified: `Views/CQLQueryField.swift` (host the button),
  `Controllers/NewConcordanceSheetController.swift`,
  `Controllers/ConcordanceViewController.swift`,
  `Settings/SettingsWindowController.swift`, `Settings/AppSettings.swift`,
  `ManateeKit/Sources/CManatee/{include/mtcbridge.h,mtcbridge.cc}`,
  `ManateeKit/Sources/ManateeKit/ManateeKit.swift`. No new package
  dependency in v1 (FoundationModels is a system framework, weak-linked).

## Phases
0. Copy plan into docs/. **Feasibility spike (no app code)** — blocked
   until `fm available` stops reporting `modelNotReady` (Apple Intelligence
   model still downloading on this Mac). With `fm respond --schema` (schema
   from `fm schema`), run ~20 English requests against a UD-annotated
   corpus (import one if none is at hand, e.g. a UD English treebank
   converted to vertical); score each by hand (valid? same hits as the
   intended query?). Record the model variant (`core3` vs `coreAdvanced3`)
   and `contextSize` on this M3 Ultra — a base-M1 Mac gets the smaller Core
   model, so also test with the prompt trimmed to 4096 tokens.
   **Go/no-go:** if Apple's model is clearly unusable even with the
   structure + examples, stop and re-plan with the MLX model as the
   baseline.
1. Engine additions + tests (ManateeKit, `swift test`).
2. `CQLSerializer` + `QueryPlan` + `QueryContextBuilder` + example banks,
   unit-tested without any model.
3. `QueryAssistant` with Apple backend + tools + retry; Evaluations-framework
   benchmark (`@Test(.evaluates…)`, `ModelSample(prompt:expected:)`,
   evaluator = hit-set equality against the expected query on the corpus).
4. UI (popover, both entry points) + Settings pane.
5. **Decision point:** from the phase-3 benchmark, estimate what
   fine-tuning would buy (run the same benchmark on an untuned Qwen3.5-2B
   via MLX as a proxy floor). Proceed to 6 only if the gap is large.
6. (Optional tier) Fine-tuned MLX model:
   - Training data, generated dev-side, never shipped: sample valid
     QueryPlans from templates over real UD and Czech positional corpora,
     keep those with non-empty hits (engine-verified), back-translate each
     to several English and Czech requests with a large LLM, human-review a
     sample. (Same idea as Mikušek's 2026 MUNI thesis on Sketch Engine
     query logs.)
   - LoRA fine-tune with `mlx-lm` (Python, dev machine) on a small base
     model (Qwen3.5-2B, Apache-2.0), merge, quantize to 4-bit (~1.3 GB).
   - App: `mlx-swift-lm` `MLXFoundationModels` backend (macOS 27 SDK),
     pinned; on-demand download from a GitHub release asset, SHA-256
     pinned, to Application Support/Korpora/Models (visible in Finder),
     progress + delete in the Settings "Assistant" pane; ships the
     `czech-positional` example bank. Release build must still sign +
     notarize with the MLX package (its `default.metallib` bundle).

## Verification
- Unit: serializer round-trips, context budget never exceeds `contextSize`,
  bridge fns (validate: good/bad queries, error position; top values on
  DevCorpus).
- Benchmark: ≥100 English NL→CQL pairs on a UD corpus for the baseline
  (+ Czech requests on a Czech positional corpus for the optional tier,
  held out from training data); execution accuracy = same hit set as the
  gold query. Acceptance bar set after the spike.
- Manual: Xcode click-through on macOS 27 (both entry points; each
  unavailable state, incl. Apple Intelligence off); Release build still
  signs + notarizes (`scripts/make-release.sh`); in the macOS 15 VM
  (`scripts/release-smoke-vm.sh`) the app launches, shows no assistant UI,
  and doesn't crash on the weak-linked framework.
