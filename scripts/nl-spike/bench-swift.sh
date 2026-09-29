#!/bin/bash
# The dev split through the app's Swift generation path (KorporaGeneration's
# QueryAssistant: prompt, EBNF-guided MLX generation, repair, engine check,
# one retry), scored by run.py --rescore. Like bench-dev.sh, dev split only.
#
#   scripts/nl-spike/bench-swift.sh TAG [MODEL...]      (mlx-community/ names)
#   GEN_FLAGS="--no-retry --spaced" scripts/nl-spike/bench-swift.sh TAG ...
#
# Build first (Release; Debug's unoptimized MLX/XGrammar C++ is ~15x slower):
#   (cd KorporaGeneration && xcodebuild -scheme korpora-generate \
#       -destination platform=macOS -configuration Release \
#       -derivedDataPath .build/xcode build)
# Models are read from the Hugging Face cache (HF_HUB_CACHE, else
# ~/.cache/huggingface/hub); fetch one with run.py or `hf download`.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
tag=$1; shift
models=${*:-Qwen3-4B-4bit Qwen3-8B-4bit}
G=KorporaGeneration/.build/xcode/Build/Products/Release/korpora-generate
HUB=${HF_HUB_CACHE:-$HOME/.cache/huggingface/hub}
OUT=data/nl-spike
export MANATEE_REGISTRY=$ROOT/data/ud-en-ewt/registry
DEV=scripts/nl-spike/bench/ud-en-ewt-dev.tsv
for m in $models; do
  dir=$(ls -d "$HUB"/models--mlx-community--$m/snapshots/*/ | head -1)
  res=$OUT/results-$m-swift-dev-$tag.tsv
  # shellcheck disable=SC2086  # GEN_FLAGS is a word list on purpose
  $G bench ud_en_ewt "$dir" $DEV ${GEN_FLAGS:-} > "$res" 2> $OUT/log-swift-dev-$tag-$m.txt
  echo "$m: $(awk -F'\t' '{s+=$8} END {printf "%.1f s/request", s/NR}' "$res"), $(grep -c retried "$res" || true) retried"
  data/.venv-nl/bin/python scripts/nl-spike/run.py x $DEV --rescore "$res"
done
