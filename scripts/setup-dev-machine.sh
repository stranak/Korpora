#!/bin/sh
# Sets up a fresh Mac to build manatee-open + ManateeKit.
# Run from this repo's checkout root, after both `manatee-open` and
# `ManateeKit` are present as siblings (this script's grandparent dir).
#
# Prerequisites this does NOT install: Xcode Command Line Tools.
# Run `xcode-select --install` first if `clang`/`swift` aren't found.
set -e

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

if [ ! -d "$ROOT/manatee-open" ] || [ ! -d "$ROOT/ManateeKit" ]; then
    echo "error: expected $ROOT/manatee-open and $ROOT/ManateeKit to both exist." >&2
    echo "Clone/copy them here first (see the commit message / chat history for how)." >&2
    exit 1
fi

echo "==> Installing build dependencies via Homebrew"
brew install autoconf automake autoconf-archive libtool bison swig pcre2 pkg-config

# bison and libtool are keg-only on Homebrew (macOS ships ancient versions),
# and libtool's GNU-compatible binaries live under a gnubin dir.
export PATH="$(brew --prefix bison)/bin:$(brew --prefix libtool)/libexec/gnubin:$(brew --prefix)/bin:$PATH"

echo "==> Building manatee-open ($(cd "$ROOT/manatee-open" && git branch --show-current))"
cd "$ROOT/manatee-open"
autoreconf --install --force
./configure --with-pcre2 --disable-python
make -j"$(sysctl -n hw.ncpu)"

echo "==> Building ManateeKit"
cd "$ROOT/ManateeKit"
swift build

echo "==> Smoke-testing against a tiny hand-built corpus"
TESTDIR="$(mktemp -d)"
mkdir -p "$TESTDIR/vert" "$TESTDIR/registry" "$TESTDIR/data"
cat > "$TESTDIR/vert/test.vert" << 'EOF'
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
EOF
cat > "$TESTDIR/registry/testcorp" << EOF
NAME "Test Corpus"
INFO "tiny smoke-test corpus"
PATH "$TESTDIR/data"
VERTICAL "$TESTDIR/vert/test.vert"
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
export MANATEE_REGISTRY="$TESTDIR/registry"
"$ROOT/manatee-open/src/encodevert" -v -c testcorp > /dev/null
"$ROOT/ManateeKit/.build/debug/manateekit-cli" testcorp '[tag="JJ"][tag="NN"]'
rm -rf "$TESTDIR"

echo "==> Done. Expected output above: 2 hits, 'brown fox' and 'lazy dog'."
