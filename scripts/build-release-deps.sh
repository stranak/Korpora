#!/bin/bash
# Builds the two things a shippable Korpora.app needs that the dev setup
# does NOT provide (see docs/project-plan.md, "Goal - Ship a signed GitHub
# release", blockers 1 and 2):
#
#   1. pcre2 built --disable-shared from a pinned source tarball. The
#      dev-time Homebrew pcre2 resolves `-lpcre2-8` to its dylib, baking an
#      absolute /opt/homebrew path into every linked binary - fatal on a
#      Mac without Homebrew. With only a .a in the prefix, the *existing*
#      `-lpcre2-8` flags (manatee-open's configure via pcre2-config, and
#      ManateeKit's Package.swift via pkg-config) pick it up statically
#      with zero flag surgery.
#
#   2. manatee-open rebuilt in an isolated `git worktree` at the release
#      deployment floor ($FLOOR) - producing encodevert/mkregexattr with
#      static pcre2 for bundling into the app, and a libbuiltinmanatee.a
#      whose objects declare that floor instead of the local OS version.
#      The dev checkout is never touched.
#
# Usage:
#   scripts/build-release-deps.sh              # FLOOR=15.0 ARCH=arm64
#   FLOOR=14.0 ARCH=x86_64 scripts/build-release-deps.sh
#
# On success it prints the three env vars the app build needs.
set -euo pipefail

FLOOR="${FLOOR:-15.0}"
ARCH="${ARCH:-arm64}"

PCRE2_VERSION="10.48"   # same version the dev build is validated against
PCRE2_SHA256="ebcc25aadf2a51fa1fefa9b8bc9e7a79b3dae86870a0f1152a22e42befd46888"
PCRE2_URL="https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.gz"

# The fork must be the portability branch, not upstream (see CLAUDE.md /
# project-plan "Repository state"). Override MANATEE_REF=<ref> to build a
# different one deliberately.
REQUIRED_BRANCH="macos-arm64-portability"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
DEP="$ROOT/.release-deps"
MANATEE_DEV="$ROOT/manatee-open"
NCPU="$(sysctl -n hw.ncpu)"

# autoreconf/automake come from Homebrew on Apple Silicon; also makes
# pkg-config findable if it isn't on PATH for the caller. bison and libtool
# are keg-only (macOS ships bison 2.3; manatee-open's configure needs
# >= 3.0.2), so put them first exactly as setup-dev-machine.sh does. These
# are build-time tools only - nothing from them lands in a shipped binary.
[ -d /opt/homebrew/bin ] && PATH="/opt/homebrew/bin:$PATH"
if command -v brew >/dev/null; then
    PATH="$(brew --prefix bison)/bin:$(brew --prefix libtool)/libexec/gnubin:$PATH"
fi

die() { echo "ERROR: $*" >&2; exit 1; }

[ -d "$MANATEE_DEV/.git" ] || die "manatee-open checkout not found at $MANATEE_DEV"
MANATEE_BRANCH="$(git -C "$MANATEE_DEV" branch --show-current)"
if [ -z "${MANATEE_REF:-}" ] && [ "$MANATEE_BRANCH" != "$REQUIRED_BRANCH" ]; then
    die "manatee-open is on branch '$MANATEE_BRANCH', expected '$REQUIRED_BRANCH'. Switch branch or set MANATEE_REF=<ref>."
fi
MANATEE_REF="${MANATEE_REF:-HEAD}"
# A dirty dev tree is fine (the worktree builds from the *commit*), but say
# so loudly - silently missing local fixes in a release build is worse.
if ! git -C "$MANATEE_DEV" diff --quiet HEAD --; then
    echo "WARNING: manatee-open has uncommitted changes at $MANATEE_REF; release build uses the committed state only." >&2
fi

ARCH_FLAGS="-arch $ARCH -mmacosx-version-min=$FLOOR"
mkdir -p "$DEP/src-cache"

# ---------------------------------------------------------------- pcre2 ----
PCRE2_PREFIX="$DEP/pcre2"
if [ -f "$PCRE2_PREFIX/.build-ok" ]; then
    echo "==> pcre2 $PCRE2_VERSION already built at $PCRE2_PREFIX (delete .build-ok to force rebuild)"
else
    echo "==> Fetching and verifying pcre2 $PCRE2_VERSION"
    TARBALL="$DEP/src-cache/pcre2-$PCRE2_VERSION.tar.gz"
    if [ ! -f "$TARBALL" ]; then
        curl -fsSL -o "$TARBALL" "$PCRE2_URL"
    fi
    echo "$PCRE2_SHA256  $TARBALL" | shasum -a 256 -c - || die "pcre2 tarball checksum mismatch"

    echo "==> Building pcre2 static-only ($ARCH, floor $FLOOR)"
    # No recursive cleanup anywhere in this script: `.release-deps` is a
    # throwaway gitignored tree, `tar` overwrites the source tree and
    # `make install` overwrites the prefix in place, and a rebuild is
    # reached only by deleting the `.build-ok` marker below - so nothing
    # stale needs clearing. (Recursive-force deletion in a script body also
    # sends Claude Code's Bash permission classifier down a slow path that
    # times out and blocks every command referencing the file - avoidable
    # here anyway, so doubly not worth it.)
    tar -xzf "$TARBALL" -C "$DEP"
    (
        cd "$DEP/pcre2-$PCRE2_VERSION"
        # Widths manatee/Package.swift never reference (only -lpcre2-8),
        # and the libedit/zlib/bz2 knobs off so the tool binaries build
        # with no dependencies beyond what a bare macOS has.
        CFLAGS="-O2 $ARCH_FLAGS" \
        ./configure --prefix="$PCRE2_PREFIX" \
            --disable-shared \
            --disable-pcre2-16 --disable-pcre2-32 \
            --disable-pcre2test-libedit --disable-pcre2grep-libz --disable-pcre2grep-libbz2 \
            >/dev/null
        make -j"$NCPU" >/dev/null
        make install >/dev/null
    )
    # Drop the libtool archives (as Homebrew does). With libpcre2-8.la
    # present, libtool resolves manatee's `-lpcre2-8` to that static-only
    # .la and silently omits it from the finlib convenience library's
    # dependency_libs - every tool link then fails with undefined
    # _pcre2_* symbols. Without the .la it's a plain linker flag, which ld
    # resolves to the prefix's lone libpcre2-8.a.
    rm -f "$PCRE2_PREFIX/lib/libpcre2-8.la" "$PCRE2_PREFIX/lib/libpcre2-posix.la"
    touch "$PCRE2_PREFIX/.build-ok"
fi
[ -x "$PCRE2_PREFIX/bin/pcre2-config" ] || die "pcre2-config missing from $PCRE2_PREFIX/bin"
[ "$( "$PCRE2_PREFIX/bin/pcre2-config" --version )" = "$PCRE2_VERSION" ] \
    || die "pcre2-config version mismatch"
ls "$PCRE2_PREFIX/lib"/libpcre2-8.a >/dev/null || die "static libpcre2-8.a missing"
if ls "$PCRE2_PREFIX/lib"/libpcre2-8*.dylib >/dev/null 2>&1; then
    die "shared libpcre2 present in prefix - -lpcre2-8 would resolve to the dylib again"
fi

# ------------------------------------------------------------ manatee ------
MANATEE_WT="$DEP/manatee"
echo "==> Rebuilding manatee-open in worktree at $FLOOR/$ARCH (dev checkout untouched)"
# Reuse the worktree if it already exists (re-syncing it to $MANATEE_REF)
# rather than force-removing and re-adding it - no recursive delete, and
# autoreconf + configure + make below regenerate every artifact anyway.
if git -C "$MANATEE_DEV" worktree list --porcelain | grep -qxF "worktree $MANATEE_WT"; then
    echo "    reusing existing worktree, syncing to $MANATEE_REF"
    git -C "$MANATEE_WT" checkout --detach "$MANATEE_REF"
else
    git -C "$MANATEE_DEV" worktree add --detach "$MANATEE_WT" "$MANATEE_REF"
fi
(
    cd "$MANATEE_WT"
    autoreconf --install >/dev/null
    # PATH puts the static-only pcre2-config first, so configure bakes the
    # prefix (with only .a in libdir) into encodevert/mkregexattr.
    PATH="$PCRE2_PREFIX/bin:$PATH" \
    CFLAGS="-O2 $ARCH_FLAGS" \
    CXXFLAGS="-O2 $ARCH_FLAGS" \
    LDFLAGS="$ARCH_FLAGS" \
    ./configure --with-pcre2 --disable-python >/dev/null
    make -j"$NCPU" >/dev/null
)

# ------------------------------------------------------- verification ------
echo "==> Verifying no Homebrew dylib leaked into the release tools"
for tool in encodevert mkregexattr; do
    [ -x "$MANATEE_WT/src/$tool" ] || die "$tool missing from $MANATEE_WT/src"
    if otool -L "$MANATEE_WT/src/$tool" | grep -q '/opt/homebrew'; then
        echo "--- otool -L $tool ---" >&2
        otool -L "$MANATEE_WT/src/$tool" >&2
        die "$tool still links a /opt/homebrew library"
    fi
    echo "    $tool: clean"
done
otool -L "$MANATEE_WT/src/encodevert" | grep -q 'pcre2' \
    && die "encodevert still has a pcre2 dylib load command (static link expected: none)" \
    || true

echo
echo "Release dependencies ready. For the app build (Release config):"
cat <<EOF
  export KORPORA_MANATEE_ROOT="$MANATEE_WT"
  export PKG_CONFIG_PATH="$PCRE2_PREFIX/lib/pkgconfig"
  export MANATEE_TOOLS_DIR="$MANATEE_WT/src"
  xcodebuild -project Korpora.xcodeproj -scheme Korpora -configuration Release \\
      MACOSX_DEPLOYMENT_TARGET=$FLOOR ...
EOF
