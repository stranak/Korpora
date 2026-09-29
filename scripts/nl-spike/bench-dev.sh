#!/bin/bash
# Runs the app's prompt builder, schema, repair and serializer
# (KorporaAssistant) on the UD English EWT dev split and prints the score
# per model. Dev-only: the test split (bench/ud-en-ewt-test.tsv) is for
# final comparisons and must not be used to tune prompts - see
# docs/nl-query-assistant.md, "Benchmark".
#
#   scripts/nl-spike/bench-dev.sh TAG [MODEL...]     (mlx-community/ names)
#   FLAGS="--level 2 --no-retrieval" scripts/nl-spike/bench-dev.sh TAG ...
#
# FLAGS go to `korpora-assistant prompts` (prompt variants). Needs
# data/.venv-nl (see run.py) and `swift build` in KorporaAssistant/.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
tag=$1; shift
models=${*:-Qwen3-4B-4bit Qwen3-8B-4bit}
B=KorporaAssistant/.build/debug/korpora-assistant
OUT=data/nl-spike
export MANATEE_REGISTRY=$ROOT/data/ud-en-ewt/registry
mkdir -p $OUT
$B schema ud_en_ewt > $OUT/schema-app.json
# shellcheck disable=SC2086  # FLAGS is a word list on purpose
$B prompts ud_en_ewt scripts/nl-spike/bench/ud-en-ewt-dev.tsv ${FLAGS:-} > $OUT/prompts-bench-dev-$tag.jsonl
for m in $models; do
  data/.venv-nl/bin/python scripts/nl-spike/run.py mlx-community/$m scripts/nl-spike/bench/ud-en-ewt-dev.tsv \
    --app-cli $B --schema $OUT/schema-app.json --prompts $OUT/prompts-bench-dev-$tag.jsonl \
    "--tag=-bench-dev-$tag" > $OUT/log-bench-dev-$tag-$m.txt 2>&1
  tail -3 $OUT/log-bench-dev-$tag-$m.txt | grep .
done
