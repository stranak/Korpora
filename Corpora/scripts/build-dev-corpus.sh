#!/bin/sh
# Builds the tiny corpus the Xcode scheme points MANATEE_REGISTRY at, so
# running Corpora from Xcode has a real corpus to pick in the "New
# Concordance" sheet instead of an empty picker. Deliberately NOT the same
# corpus as ManateeKit's TestCorpusFixture (which stays a minimal 2-<doc>
# fixture for fast, deterministic automated tests) - this one has 5 <doc>s
# with author/genre/year attributes, so subcorpora actually restrict to a
# real *subset* of documents rather than just one out of two. Safe to
# re-run, it just regenerates .devcorpus/.
set -e
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CORPUS="$ROOT/.devcorpus"

rm -rf "$CORPUS"
mkdir -p "$CORPUS/vert" "$CORPUS/registry" "$CORPUS/data"

cat > "$CORPUS/vert/test.vert" << 'EOF'
<doc id="1" author="twain" genre="fiction" year="1876">
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
<doc id="2" author="twain" genre="fiction" year="1884">
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
<doc id="3" author="austen" genre="fiction" year="1813">
<s>
the	the	DT
elegant	elegant	JJ
lady	lady	NN
smiles	smile	VBZ
</s>
<s>
a	a	DT
proud	proud	JJ
gentleman	gentleman	NN
bows	bow	VBZ
</s>
</doc>
<doc id="4" author="reuters" genre="news" year="2020">
<s>
the	the	DT
local	local	JJ
market	market	NN
grows	grow	VBZ
</s>
<s>
a	a	DT
global	global	JJ
economy	economy	NN
shifts	shift	VBZ
</s>
</doc>
<doc id="5" author="reuters" genre="news" year="2021">
<s>
the	the	DT
annual	annual	JJ
report	report	NN
shows	show	VBZ
</s>
<s>
a	a	DT
modest	modest	JJ
profit	profit	NN
rises	rise	VBZ
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
    ATTRIBUTE author
    ATTRIBUTE genre
    ATTRIBUTE year
}
STRUCTURE s {
}
EOF

MANATEE_REGISTRY="$CORPUS/registry" "$ROOT/../manatee-open/src/encodevert" -v -c testcorp
echo "==> Built dev corpus 'testcorp' at $CORPUS"
