#!/bin/sh
# Builds the tiny corpus the Xcode scheme points MANATEE_REGISTRY at, so
# running Corpora from Xcode has a real corpus to pick in the "New
# Concordance" sheet instead of an empty picker. Same corpus as
# ManateeKit's TestCorpusFixture (two <doc>s, so there's something real to
# restrict a subcorpus to) - safe to re-run, it just regenerates .devcorpus/.
set -e
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CORPUS="$ROOT/.devcorpus"

rm -rf "$CORPUS"
mkdir -p "$CORPUS/vert" "$CORPUS/registry" "$CORPUS/data"

cat > "$CORPUS/vert/test.vert" << 'EOF'
<doc id="1">
<s>
the	the	DT
quick	quick	JJ
brown	brown	JJ
fox	fox	NN
jumps	jump	VBZ
</s>
<s>
the	the	DT
lazy	lazy	JJ
dog	dog	NN
sleeps	sleep	VBZ
</s>
</doc>
<doc id="2">
<s>
a	a	DT
curious	curious	JJ
cat	cat	NN
purrs	purr	VBZ
</s>
<s>
the	the	DT
sleepy	sleepy	JJ
cat	cat	NN
yawns	yawn	VBZ
</s>
</doc>
EOF

cat > "$CORPUS/registry/testcorp" << EOF
NAME "Test Corpus"
INFO "tiny dev-only corpus for running Corpora from Xcode"
PATH "$CORPUS/data"
VERTICAL "$CORPUS/vert/test.vert"
LANGUAGE "en"
ENCODING "utf-8"

ATTRIBUTE word
ATTRIBUTE lemma {
}
ATTRIBUTE tag {
}
STRUCTURE doc {
    ATTRIBUTE id
}
STRUCTURE s {
}
EOF

MANATEE_REGISTRY="$CORPUS/registry" "$ROOT/../manatee-open/src/encodevert" -v -c testcorp
echo "==> Built dev corpus 'testcorp' at $CORPUS"
