#!/bin/bash
# Downloads the benchmarked MLX models at their pinned revisions
# (models.tsv) into the Hugging Face cache.
#
#   scripts/nl-spike/fetch-models.sh               # the two in current use (Qwen3-4B, Qwen3-8B)
#   scripts/nl-spike/fetch-models.sh all           # everything in models.tsv
#   scripts/nl-spike/fetch-models.sh Qwen3-4B-4bit # by name
#
# Needs data/.venv-nl (requirements.txt), which provides the `hf` CLI.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HF="$ROOT/data/.venv-nl/bin/hf"
[ -x "$HF" ] || { echo "ERROR: $HF missing - set up data/.venv-nl first (requirements.txt)" >&2; exit 1; }
want=${*:-Qwen3-4B-4bit Qwen3-8B-4bit}
grep -v '^#' "$ROOT/scripts/nl-spike/models.tsv" | while IFS=$'\t' read -r repo revision size; do
    name=${repo#*/}
    if [ "$want" = all ] || [[ " $want " == *" $name "* ]]; then
        echo "==> $repo @ ${revision:0:7} (~$size GB)"
        "$HF" download "$repo" --revision "$revision" >/dev/null
    fi
done
