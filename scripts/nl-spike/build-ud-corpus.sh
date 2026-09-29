#!/bin/bash
# Builds the query-assistant benchmark corpus, UD English EWT, into
# data/ud-en-ewt/ (gitignored): the vertical file, a registry with this
# machine's paths, and the compiled indices. See corpus/README.md for
# provenance and license. Safe to re-run.
#
#   scripts/nl-spike/build-ud-corpus.sh                # from the committed vertical
#   scripts/nl-spike/build-ud-corpus.sh --from-source  # re-download the pinned CoNLL-U,
#                                                      # convert, check it matches
#
# Then: export MANATEE_REGISTRY=$PWD/data/ud-en-ewt/registry (corpus ud_en_ewt).
# Needs a built manatee-open checkout's encodevert: $MANATEE_OPEN, else
# ./manatee-open or the sibling ../manatee-open (docs/project-plan.md).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/scripts/nl-spike"
OUT="$ROOT/data/ud-en-ewt"
VERT="$OUT/ud-en-ewt.vert"
SHA=385cd3a445ad5d65bb126dd52a6393b14687fe60837fb47d820f4878cf8e5545
UD_COMMIT=4a4d77f599ea53cc405f85d0cec4b2f14f81d42b

ENCODEVERT=""
for m in ${MANATEE_OPEN:+"$MANATEE_OPEN"} "$ROOT/manatee-open" "$ROOT/../manatee-open"; do
    [ -x "$m/src/encodevert" ] && { ENCODEVERT="$m/src/encodevert"; break; }
done
[ -n "$ENCODEVERT" ] || { echo "ERROR: no built manatee-open/src/encodevert found" >&2; exit 1; }

mkdir -p "$OUT/registry"
if [ "${1:-}" = "--from-source" ]; then
    for part in train dev test; do
        curl -sfL -o "$OUT/en_ewt-ud-$part.conllu" \
            "https://raw.githubusercontent.com/UniversalDependencies/UD_English-EWT/$UD_COMMIT/en_ewt-ud-$part.conllu"
    done
    curl -sfL -o "$OUT/LICENSE.txt" \
        "https://raw.githubusercontent.com/UniversalDependencies/UD_English-EWT/$UD_COMMIT/LICENSE.txt"
    python3 "$ROOT/scripts/conllu2vert.py" "$VERT" \
        "$OUT/en_ewt-ud-train.conllu" "$OUT/en_ewt-ud-dev.conllu" "$OUT/en_ewt-ud-test.conllu"
else
    xz -dc "$HERE/corpus/ud-en-ewt.vert.xz" > "$VERT"
fi
got=$(shasum -a 256 "$VERT" | cut -d' ' -f1)
[ "$got" = "$SHA" ] || { echo "ERROR: $VERT has SHA-256 $got, expected $SHA" >&2; exit 1; }

cat > "$OUT/registry/ud_en_ewt" <<REG
NAME "UD English EWT"
INFO "Universal Dependencies English Web Treebank (CC BY-SA 4.0) - test corpus for the NL query assistant"
PATH "$OUT/compiled"
VERTICAL "$VERT"
LANGUAGE "en"
ENCODING "utf-8"

ATTRIBUTE word
ATTRIBUTE lemma {
}
ATTRIBUTE upos {
}
ATTRIBUTE xpos {
}
ATTRIBUTE feats {
    MULTIVALUE yes
    MULTISEP "|"
}
ATTRIBUTE deprel {
}
STRUCTURE doc {
    ATTRIBUTE id
    ATTRIBUTE genre
    ATTRIBUTE split
}
STRUCTURE s {
    ATTRIBUTE id
}
REG

rm -rf "$OUT/compiled"
mkdir -p "$OUT/compiled"
MANATEE_REGISTRY="$OUT/registry" "$ENCODEVERT" -c ud_en_ewt > "$OUT/encode.log" 2>&1 \
    || { tail -20 "$OUT/encode.log" >&2; exit 1; }
echo "==> Built ud_en_ewt in $OUT"
echo "    export MANATEE_REGISTRY=$OUT/registry"
