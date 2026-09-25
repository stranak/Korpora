#!/bin/bash
# Builds the distributable Korpora.dmg: Release build (Developer ID signed,
# hardened runtime, bundled + signed import tools - project.yml's Release
# config) -> signature checks -> app notarized + stapled -> DMG (with an
# Applications link) around the stapled app -> DMG signed, notarized +
# stapled -> Gatekeeper checks on a quarantined copy. See docs/project-plan.md,
# "Goal - Ship a signed GitHub release", step 5.
#
# Prerequisites:
#   - scripts/build-release-deps.sh has been run (static pcre2 + release
#     manatee-open worktree in .release-deps/).
#   - A "Developer ID Application" identity for team 8YW3ZU8MFU in the
#     keychain.
#   - Notary credentials stored once under a keychain profile:
#       xcrun notarytool store-credentials korpora-notary \
#           --apple-id <Apple ID> --team-id 8YW3ZU8MFU
#     (or with --key/--key-id/--issuer for an App Store Connect API key).
#
# Usage:
#   scripts/make-release.sh                  # full pipeline
#   scripts/make-release.sh --skip-notarize  # build + DMG + signature checks only
#
# Env overrides: NOTARY_PROFILE (default korpora-notary), SIGN_IDENTITY
# (default "Developer ID Application").
#
# Output: release/Korpora-<version>.dmg and its .sha256 next to it.
set -euo pipefail

NOTARY_PROFILE="${NOTARY_PROFILE:-korpora-notary}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
TEAM_ID="8YW3ZU8MFU"
NOTARIZE=yes
[ "${1:-}" = "--skip-notarize" ] && NOTARIZE=no

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
DEP="$ROOT/.release-deps"
OUT="$ROOT/release"
DERIVED="$DEP/DerivedData"

die() { echo "ERROR: $*" >&2; exit 1; }

# codesign --timestamp depends on Apple's timestamp server, which has been
# seen to return one transient bad response ("timestamps differ by N
# seconds") with a correct local clock. Retry instead of failing a release.
retry3() {
    local attempt
    for attempt in 1 2 3; do
        "$@" && return 0
        echo "    attempt $attempt/3 failed: $*" >&2
        sleep 5
    done
    return 1
}

# ------------------------------------------------------- preconditions ----
[ -f "$DEP/pcre2/.build-ok" ] || die "release deps missing - run scripts/build-release-deps.sh first"
[ -x "$DEP/manatee/src/encodevert" ] || die "release manatee-open tools missing - run scripts/build-release-deps.sh first"
security find-identity -v -p codesigning | grep -q "\"$SIGN_IDENTITY: .*($TEAM_ID)\"" \
    || die "no valid '$SIGN_IDENTITY' identity for team $TEAM_ID in the keychain"
if [ "$NOTARIZE" = yes ]; then
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
        || die "notary profile '$NOTARY_PROFILE' missing or rejected - see the header for store-credentials"
fi
if ! git -C "$ROOT" diff --quiet HEAD --; then
    echo "WARNING: uncommitted changes in $ROOT - they WILL be in this build." >&2
fi

# ------------------------------------------------------------- build ----
echo "==> Building Release (clean)"
export KORPORA_MANATEE_ROOT="$DEP/manatee"
export PKG_CONFIG_PATH="$DEP/pcre2/lib/pkgconfig"
export MANATEE_TOOLS_DIR="$DEP/manatee/src"
mkdir -p "$OUT"
BUILD_LOG="$OUT/build.log"
xcodebuild -project "$ROOT/Korpora/Korpora.xcodeproj" -scheme Korpora \
    -configuration Release -derivedDataPath "$DERIVED" clean build \
    > "$BUILD_LOG" 2>&1 \
    || { tail -30 "$BUILD_LOG" >&2; die "xcodebuild failed - full log: $BUILD_LOG"; }
APP="$DERIVED/Build/Products/Release/Korpora.app"
[ -d "$APP" ] || die "build succeeded but $APP is missing"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")"
echo "    Korpora $VERSION ($BUILD)"

# -------------------------------------------------- signature checks ----
echo "==> Checking signatures"
for bin in "$APP" "$APP/Contents/Helpers/encodevert" "$APP/Contents/Helpers/mkregexattr"; do
    info="$(codesign -dvv "$bin" 2>&1)" || die "not signed: $bin"
    grep -q "^Authority=Developer ID Application: .*($TEAM_ID)" <<<"$info" \
        || die "not signed with Developer ID ($TEAM_ID): $bin"
    grep -q "flags=0x10000(runtime)" <<<"$info" || die "hardened runtime missing: $bin"
    grep -q "^Timestamp=" <<<"$info" || die "no secure timestamp: $bin"
    echo "    ok: ${bin#"$APP/"}"
done
codesign --verify --deep --strict "$APP" || die "codesign --verify --deep --strict failed"
# The notary service rejects the debugger-attach entitlement; catch it here
# rather than after an upload round trip.
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow; then
    die "app is signed with com.apple.security.get-task-allow (CODE_SIGN_INJECT_BASE_ENTITLEMENTS must be NO for Release)"
fi
if otool -L "$APP/Contents/MacOS/Korpora" "$APP/Contents/Helpers/"* | grep -q /opt/homebrew; then
    die "a binary still links a /opt/homebrew library"
fi

# Notarize one artifact and staple its ticket. The app and the DMG are
# notarized separately so that *both* carry a stapled ticket: the DMG's
# covers first open of the download, the app's covers it after it has been
# dragged to /Applications - offline in both cases.
notarize() {  # <file-to-submit> <what-to-staple> <label>
    local submit="$1" staple="$2" label="$3"
    local result="$OUT/notary-$label.json" status sub_id
    echo "==> Notarizing $label (waits for Apple's verdict, usually minutes)"
    xcrun notarytool submit "$submit" --keychain-profile "$NOTARY_PROFILE" \
        --wait --output-format json > "$result" \
        || true   # non-zero on Invalid too; the status below decides
    status="$(plutil -extract status raw -o - "$result" 2>/dev/null || echo unknown)"
    sub_id="$(plutil -extract id raw -o - "$result" 2>/dev/null || echo '')"
    echo "    submission $sub_id: $status"
    if [ -n "$sub_id" ]; then
        xcrun notarytool log "$sub_id" --keychain-profile "$NOTARY_PROFILE" \
            "$OUT/notary-$label-log.json" >/dev/null 2>&1 || true
    fi
    [ "$status" = "Accepted" ] \
        || die "$label notarization not accepted (status: $status) - Apple's log: $OUT/notary-$label-log.json"
    retry3 xcrun stapler staple "$staple" >/dev/null
    xcrun stapler validate "$staple" >/dev/null || die "stapled ticket on $label does not validate"
    echo "    stapled + validated: $staple"
}

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/korpora-release.XXXXXX")"
mkdir "$STAGE/dmgroot"
ditto "$APP" "$STAGE/dmgroot/Korpora.app"
STAGED_APP="$STAGE/dmgroot/Korpora.app"

if [ "$NOTARIZE" = yes ]; then
    ditto -c -k --keepParent "$STAGED_APP" "$STAGE/Korpora.zip"
    notarize "$STAGE/Korpora.zip" "$STAGED_APP" app
fi

# ---------------------------------------------------------------- DMG ----
DMG="$OUT/Korpora-$VERSION.dmg"
echo "==> Creating $DMG"
ln -s /Applications "$STAGE/dmgroot/Applications"
hdiutil create -volname "Korpora $VERSION" -srcfolder "$STAGE/dmgroot" \
    -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
retry3 codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG" \
    || die "signing the DMG failed"

if [ "$NOTARIZE" = yes ]; then
    notarize "$DMG" "$DMG" dmg

    # ---------------------------------------------- Gatekeeper checks ----
    # Assess a quarantined copy - what a browser download looks like.
    echo "==> Gatekeeper assessment (quarantined copy)"
    QCOPY="$STAGE/downloaded.dmg"
    cp "$DMG" "$QCOPY"
    xattr -w com.apple.quarantine "0081;$(printf %x "$(date +%s)");Safari;" "$QCOPY"
    spctl --assess --type open --context context:primary-signature -vv "$QCOPY" \
        || die "Gatekeeper rejected the DMG"
    MNT="$STAGE/mnt"
    mkdir "$MNT"
    hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$QCOPY" >/dev/null
    gk_ok=yes
    spctl --assess --type execute -vv "$MNT/Korpora.app" || gk_ok=no
    xcrun stapler validate "$MNT/Korpora.app" >/dev/null || gk_ok=no
    hdiutil detach "$MNT" >/dev/null
    [ "$gk_ok" = yes ] || die "Gatekeeper rejected the app inside the DMG, or its ticket is missing"
else
    echo "==> Skipped notarization (--skip-notarize): this DMG is NOT distributable"
fi

# ----------------------------------------------------------- output ----
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo
echo "Done: $DMG"
cat "$DMG.sha256"
