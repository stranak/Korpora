# Benchmark results

One file per model run, in `run.py`'s results format (tab-separated:
request, gold, generated CQL, verdict, engine error, notes - repairs and
retries -, explanation, seconds). Re-score any of them against the
current gold file, without a model, with

    data/.venv-nl/bin/python scripts/nl-spike/run.py x REQUESTS.tsv --rescore FILE

The verdict column is from the run itself; `--rescore` recomputes it
(gold alternatives were added after some runs). Files are named
`results-<model><tag>.tsv`. The tags, in order of the work
(docs/nl-query-assistant.md has the tables and conclusions):

| tag | requests | what |
|---|---|---|
| (none) | `requests.tsv` | phase 0, v1 prompt (`instructions.txt`), stock models |
| `-v1-requests`, `-v1-heldout` | phase 0 sets | v1 prompt; rebuilt from logs, only request + CQL columns |
| `-v2-requests`, `-v2-heldout` | phase 0 sets | `instructions-v2.txt` + one retry |
| `-app-requests`, `-app-heldout` | phase 0 sets | phase 2 Swift prompt builder (`korpora-assistant prompts`) |
| `-abl-L<level><r\|n>` | `requests.tsv` | phase 2 ablation: detail level, retrieval on (r) / off (n) |
| `-bench-dev-v1` | `bench/ud-en-ewt-dev.tsv` | v1 prompt on the 60-item dev split |
| `-bench-dev-v1-appschema` | dev split | v1 prompt, app schema + serializer |
| `-bench-dev-app`, `-app2`, `-app3` | dev split | app prompt, successive versions (app3 = current default) |
| `-bench-dev-app4-*` | dev split | app3 variants: curated lists, v1 rules, level 2/3, fixed examples, no glosses |
| `-swift-dev-*` | dev split | the Swift generation path (`bench-swift.sh`): jump-forward on (`compact`, `spaced`), off (`noff-*`), retry on/off, "value of another attribute" feedback (`retry-foundin`) |

No results for the test split (`bench/ud-en-ewt-test.tsv`) yet - it's
kept unread for milestone comparisons.
