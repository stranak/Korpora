#!/bin/sh
# Builds the tiny corpus the Xcode scheme points MANATEE_REGISTRY at, so
# running Corpora from Xcode has a real corpus to pick in the "New
# Concordance" sheet instead of an empty picker. Deliberately NOT the same
# corpus as ManateeKit's TestCorpusFixture (which stays a minimal 2-<doc>
# fixture for fast, deterministic automated tests) - this one has 5 <doc>s
# with author/genre/year attributes, so subcorpora actually restrict to a
# real *subset* of documents rather than just one out of two. Safe to
# re-run, it just regenerates DevCorpus/. Not dot-prefixed - kept visible in
# Finder/Xcode along with the rest of the project.
#
# Every sentence is padded with >=5 tokens of filler on each side of its
# [JJ][NN] target pair (repeated verbatim, not meant to read as prose) -
# discovered the hard way that with short, back-to-back sentences, the
# Filter feature's default +/-5 token window reaches into a *neighboring*
# sentence's unrelated content word (e.g. filtering for "fox" was also
# keeping the next sentence's "dog", since they were only 4 tokens apart in
# the raw token stream). This isn't a bug in Concordance::set_collocation
# or LiveConcordance.filter - see concord/concctx.cc's prepare_context - the
# window is genuinely +/-5 raw positions from the match, same as KonText's
# own default; the old 4-5 token sentences just didn't leave it anywhere
# else to land.
set -e
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CORPUS="$ROOT/DevCorpus"

rm -rf "$CORPUS"
mkdir -p "$CORPUS/vert" "$CORPUS/registry" "$CORPUS/data"

cat > "$CORPUS/vert/test.vert" << 'EOF'
<doc id="1" author="twain" genre="fiction" year="1876">
<s>
he	he	PRP
often	often	RB
saw	see	VBD
that	that	DT
morning	morning	NN
near	near	IN
the	the	DT
quick	quick	JJ
brown	brown	JJ
fox	fox	NN
moving	move	VBG
slowly	slowly	RB
beyond	beyond	IN
some	some	DT
valley	valley	NN
quietly	quietly	RB
</s>
<s>
he	he	PRP
often	often	RB
saw	see	VBD
that	that	DT
morning	morning	NN
near	near	IN
the	the	DT
lazy	lazy	JJ
dog	dog	NN
moving	move	VBG
slowly	slowly	RB
beyond	beyond	IN
some	some	DT
valley	valley	NN
quietly	quietly	RB
</s>
</doc>
<doc id="2" author="twain" genre="fiction" year="1884">
<s>
he	he	PRP
often	often	RB
saw	see	VBD
that	that	DT
morning	morning	NN
near	near	IN
the	the	DT
curious	curious	JJ
cat	cat	NN
moving	move	VBG
slowly	slowly	RB
beyond	beyond	IN
some	some	DT
valley	valley	NN
quietly	quietly	RB
</s>
<s>
he	he	PRP
often	often	RB
saw	see	VBD
that	that	DT
morning	morning	NN
near	near	IN
the	the	DT
sleepy	sleepy	JJ
cat	cat	NN
moving	move	VBG
slowly	slowly	RB
beyond	beyond	IN
some	some	DT
valley	valley	NN
quietly	quietly	RB
</s>
</doc>
<doc id="3" author="austen" genre="fiction" year="1813">
<s>
he	he	PRP
often	often	RB
saw	see	VBD
that	that	DT
morning	morning	NN
near	near	IN
the	the	DT
elegant	elegant	JJ
lady	lady	NN
moving	move	VBG
slowly	slowly	RB
beyond	beyond	IN
some	some	DT
valley	valley	NN
quietly	quietly	RB
</s>
<s>
he	he	PRP
often	often	RB
saw	see	VBD
that	that	DT
morning	morning	NN
near	near	IN
the	the	DT
proud	proud	JJ
gentleman	gentleman	NN
moving	move	VBG
slowly	slowly	RB
beyond	beyond	IN
some	some	DT
valley	valley	NN
quietly	quietly	RB
</s>
</doc>
<doc id="4" author="reuters" genre="news" year="2020">
<s>
he	he	PRP
often	often	RB
saw	see	VBD
that	that	DT
morning	morning	NN
near	near	IN
the	the	DT
local	local	JJ
market	market	NN
moving	move	VBG
slowly	slowly	RB
beyond	beyond	IN
some	some	DT
valley	valley	NN
quietly	quietly	RB
</s>
<s>
he	he	PRP
often	often	RB
saw	see	VBD
that	that	DT
morning	morning	NN
near	near	IN
the	the	DT
global	global	JJ
economy	economy	NN
moving	move	VBG
slowly	slowly	RB
beyond	beyond	IN
some	some	DT
valley	valley	NN
quietly	quietly	RB
</s>
</doc>
<doc id="5" author="reuters" genre="news" year="2021">
<s>
he	he	PRP
often	often	RB
saw	see	VBD
that	that	DT
morning	morning	NN
near	near	IN
the	the	DT
annual	annual	JJ
report	report	NN
moving	move	VBG
slowly	slowly	RB
beyond	beyond	IN
some	some	DT
valley	valley	NN
quietly	quietly	RB
</s>
<s>
he	he	PRP
often	often	RB
saw	see	VBD
that	that	DT
morning	morning	NN
near	near	IN
the	the	DT
modest	modest	JJ
profit	profit	NN
moving	move	VBG
slowly	slowly	RB
beyond	beyond	IN
some	some	DT
valley	valley	NN
quietly	quietly	RB
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
