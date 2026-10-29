#!/bin/bash
# Trackglass for Mac release (SPEC §6.11, PLAN M11.2).
#
#   Scripts/release-mac.sh <version> [--pre-release] [--dry-run]
#
# Scripts/ci.sh → archive (build number = commit count) → Developer ID export → Info.plist checks → DMG
# → notarytool submit --wait → stapler → appcast generated and committed locally → tag → GitHub release
# → push. The appcast only goes live (push to main) after the DMG it points at is downloadable.
#
# One-time prerequisites on the release Mac (nothing here is stored in the repo):
#   • Developer ID Application certificate in the login Keychain; DEVELOPMENT_TEAM in Config/Local.xcconfig.
#   • Notarization credentials:  xcrun notarytool store-credentials "$TG_NOTARY_PROFILE"  (default profile name: trackglass-notary)
#   • Sparkle tools on PATH (generate_appcast; from the Sparkle release archive's bin/) and the EdDSA private key
#     in the Keychain, created with Sparkle's generate_keys. The public key is TG_SPARKLE_PUBLIC_KEY in Config/Shared.xcconfig (tracked; it is not a secret).
#   • gh auth login (GitHub CLI), and a release-notes file at Releases/release-notes/<version>.md.
#   • MARKETING_VERSION in Config/Shared.xcconfig must equal <version>.
#
# Guards: refuses a dirty working tree, a branch other than an up-to-date main, an existing tag (local or on
# origin), a version mismatch, a Keychain Sparkle key that does not match TG_SPARKLE_PUBLIC_KEY, a build number
# not above the appcast's newest, an exported app whose feed URL / key / versions differ from the tracked
# configuration (a Config/Local.xcconfig override), and a signing team that differs from the previously shipped
# app (SPEC §8.6, Scripts/assert-signing-team.sh). --dry-run stops before notarization. TG_RELEASE_SKIP_CI=1
# skips the test run (only for re-running a release whose CI already passed on this commit).
# Export options (Developer ID, automatic signing, the team ID from Config/Local.xcconfig) are written per run.
set -euo pipefail

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

VERSION="${1:-}"; shift || true
[[ -n "$VERSION" ]] || usage
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must look like 1.2.3 (got '$VERSION')" >&2; exit 2; }
PRERELEASE=0; DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --pre-release) PRERELEASE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    *) usage ;;
  esac
done

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TAG="v$VERSION"
NOTARY_PROFILE="${TG_NOTARY_PROFILE:-trackglass-notary}"
PRODUCT_NAME="$(sed -n 's/^TG_PRODUCT_NAME *= *//p' Config/Shared.xcconfig)"
REPO_URL="$(sed -n 's/^TG_REPO_URL *= *//p' Config/Shared.xcconfig | sed 's#\$()##')"
REPO_SLUG="${REPO_URL#https://github.com/}"
APPCAST_URL="$(sed -n 's/^TG_APPCAST_URL *= *//p' Config/Shared.xcconfig | sed 's#\$()##')"
SPARKLE_KEY="$(sed -n 's/^TG_SPARKLE_PUBLIC_KEY *= *//p' Config/Shared.xcconfig | tr -d '[:space:]')"
MARKETING_VERSION="$(sed -n 's/^MARKETING_VERSION *= *//p' Config/Shared.xcconfig)"
DMG_NAME="$PRODUCT_NAME-for-Mac-$VERSION.dmg"
NOTES="Releases/release-notes/$VERSION.md"
BUILD_DIR="${TMPDIR:-/tmp}/trackglass-release-$VERSION"
ARCHIVE="$BUILD_DIR/TrackglassMac.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
STAGING="$BUILD_DIR/dmg-root"

step() { printf '\n==> %s\n' "$*"; }
fail() { echo "error: $*" >&2; exit 1; }

step "Checking prerequisites"
[[ -z "$(git status --porcelain)" ]] || fail "working tree is dirty; commit or stash first"
[[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || fail "release from main (Sparkle reads the appcast from main)"
git fetch -q origin main || fail "cannot fetch origin/main"
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main is not level with origin/main; pull or push first"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "tag $TAG already exists"
git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1 && fail "tag $TAG already exists on origin"
[[ "$MARKETING_VERSION" == "$VERSION" ]] || fail "MARKETING_VERSION is $MARKETING_VERSION, not $VERSION (edit Config/Shared.xcconfig)"
[[ -f "$NOTES" ]] || fail "missing release notes $NOTES"
grep -qi '^DRAFT' "$NOTES" && fail "release notes $NOTES are still marked DRAFT; edit them first"
[[ -f Config/Local.xcconfig ]] && grep -q '^DEVELOPMENT_TEAM *= *[A-Z0-9]' Config/Local.xcconfig || fail "DEVELOPMENT_TEAM is not set in Config/Local.xcconfig"
grep -q '^TG_SPARKLE_PUBLIC_KEY *= *[A-Za-z0-9+/=]' Config/Shared.xcconfig || fail "TG_SPARKLE_PUBLIC_KEY is not set in Config/Shared.xcconfig (Sparkle generate_keys -p)"
if grep -q '^TG_SPARKLE_PUBLIC_KEY' Config/Local.xcconfig && ! grep -q "^$(grep '^TG_SPARKLE_PUBLIC_KEY' Config/Shared.xcconfig)\$" Config/Local.xcconfig; then
  fail "Config/Local.xcconfig overrides TG_SPARKLE_PUBLIC_KEY with a different value; delete that line"
fi
for tool in xcodegen xcodebuild hdiutil gh generate_appcast generate_keys python3; do
  command -v "$tool" >/dev/null || fail "$tool is not on PATH"
done
# An appcast signed with another key is refused by every installed copy: the Keychain's key must be the app's.
KEYCHAIN_KEY="$(generate_keys -p 2>/dev/null | tr -d '[:space:]')" || true
[[ -n "$KEYCHAIN_KEY" && "$KEYCHAIN_KEY" == "$SPARKLE_KEY" ]] \
  || fail "the Sparkle key in this Keychain ('${KEYCHAIN_KEY:-none}') is not TG_SPARKLE_PUBLIC_KEY; import the private key (generate_keys -f) first"
# Sparkle compares CFBundleVersion: every release needs a larger build number than any version in the appcast.
BUILD_NUMBER="$(git rev-list --count HEAD)"
LATEST_BUILD="$(python3 -I - Releases/appcast.xml <<'PY'
import re, sys
try:
    text = open(sys.argv[1], encoding="utf-8").read()
except FileNotFoundError:
    text = ""
print(max([int(v) for v in re.findall(r'sparkle:version(?:="|>)\s*(\d+)', text)] or [0]))
PY
)"
(( BUILD_NUMBER > LATEST_BUILD )) || fail "build number $BUILD_NUMBER is not above the appcast's newest ($LATEST_BUILD)"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || fail "notarytool profile '$NOTARY_PROFILE' is missing (xcrun notarytool store-credentials)"
gh auth status >/dev/null 2>&1 || fail "gh is not authenticated (gh auth login)"
TEAM_ID="$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Config/Local.xcconfig | tr -d '[:space:]')"
# The DMG is signed with this team's Developer ID identity, never whichever one the Keychain lists first.
SIGNING_IDENTITY="$(security find-identity -v -p codesigning | grep 'Developer ID Application' | grep "($TEAM_ID)" | head -1 | awk '{print $2}' || true)"
[[ -n "$SIGNING_IDENTITY" ]] || fail "no Developer ID Application identity for team $TEAM_ID in the Keychain"

xcodegen generate >/dev/null
if [[ "${TG_RELEASE_SKIP_CI:-0}" != 1 ]]; then
  step "Running Scripts/ci.sh (every test, signed)"
  Scripts/ci.sh
  [[ -z "$(git status --porcelain)" ]] || fail "Scripts/ci.sh left changes in the working tree"
fi

rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR" "$EXPORT_DIR" "$STAGING" Releases
# The export options carry the team ID, which never enters the repo (CLAUDE.md "Secrets"); write them per run.
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>destination</key><string>export</string>
</dict>
</plist>
PLIST

step "Archiving $PRODUCT_NAME $VERSION (build $BUILD_NUMBER)"
# -allowProvisioningUpdates: keychain-access-groups needs a Developer ID provisioning profile, which automatic
# signing creates or refreshes on demand.
xcodebuild -project Trackglass.xcodeproj -scheme TrackglassMac -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" archive | tail -3

step "Exporting with Developer ID"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$EXPORT_DIR" -allowProvisioningUpdates | tail -3
APP="$(find "$EXPORT_DIR" -maxdepth 1 -name '*.app' | head -1)"
[[ -d "$APP" ]] || fail "export produced no .app"
codesign --verify --deep --strict --verbose=2 "$APP"
[[ -f "$APP/Contents/embedded.provisionprofile" ]] || fail "the exported app has no provisioning profile (keychain-access-groups would stop it from launching)"

step "Checking the exported Info.plist against the tracked configuration"
plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist" 2>/dev/null || true; }
[[ "$(plist_value SUFeedURL)" == "$APPCAST_URL" ]] || fail "SUFeedURL is '$(plist_value SUFeedURL)', not $APPCAST_URL (Config/Local.xcconfig override?)"
[[ "$(plist_value SUPublicEDKey)" == "$SPARKLE_KEY" ]] || fail "SUPublicEDKey differs from TG_SPARKLE_PUBLIC_KEY (Config/Local.xcconfig override?)"
[[ "$(plist_value CFBundleShortVersionString)" == "$VERSION" ]] || fail "CFBundleShortVersionString is '$(plist_value CFBundleShortVersionString)', not $VERSION"
[[ "$(plist_value CFBundleVersion)" == "$BUILD_NUMBER" ]] || fail "CFBundleVersion is '$(plist_value CFBundleVersion)', not $BUILD_NUMBER"
# SPEC §8.6: the previously shipped build is the copy installed on this Mac under the exported bundle's name.
PREVIOUS_APP="${TG_PREVIOUS_APP:-/Applications/$(basename "$APP")}"

if [[ -d "$PREVIOUS_APP" ]]; then
  step "Asserting the signing team matches the previously shipped app"
  Scripts/assert-signing-team.sh "$APP" "$PREVIOUS_APP"
else
  echo "note: no previous app at $PREVIOUS_APP; skipping the team assertion (set TG_PREVIOUS_APP to check)"
fi

step "Building $DMG_NAME"
VOLUME_NAME="$PRODUCT_NAME for Mac"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
if [[ -f Design/dmg-background.png ]]; then
  mkdir -p "$STAGING/.background"; cp Design/dmg-background.png "$STAGING/.background/background.png"
fi
rm -f "Releases/$DMG_NAME"
# 1. A read-write image that Finder can lay out (background, icon positions, window size)…
RW_IMAGE="$BUILD_DIR/rw.dmg"
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGING" -ov -format UDRW -fs HFS+ "$RW_IMAGE" >/dev/null
MOUNT_POINT="/Volumes/$VOLUME_NAME"
hdiutil attach "$RW_IMAGE" -mountpoint "$MOUNT_POINT" -nobrowse -noautoopen >/dev/null
if [[ -f "$STAGING/.background/background.png" ]]; then
  # Finder writes the view options into the volume's .DS_Store; that is what the final image carries.
  osascript <<APPLESCRIPT || echo "note: Finder layout step failed; the DMG works but opens without the custom layout"
tell application "Finder"
  tell disk "$VOLUME_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 520}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set background picture of viewOptions to file ".background:background.png"
    set position of item "$(basename "$APP")" of container window to {180, 190}
    set position of item "Applications" of container window to {480, 190}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT
fi
sync
hdiutil detach "$MOUNT_POINT" -quiet || { sleep 2; hdiutil detach "$MOUNT_POINT" -force -quiet; }
# 2. …converted to the compressed, read-only image that ships.
hdiutil convert "$RW_IMAGE" -format UDZO -imagekey zlib-level=9 -o "Releases/$DMG_NAME" >/dev/null
codesign --force --sign "$SIGNING_IDENTITY" --timestamp "Releases/$DMG_NAME"

if [[ "$DRY_RUN" == 1 ]]; then
  echo "dry run: stopping before notarization. DMG at Releases/$DMG_NAME (not committed; Releases/*.dmg is ignored)."
  exit 0
fi

step "Notarizing (this waits for Apple)"
xcrun notarytool submit "Releases/$DMG_NAME" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "Releases/$DMG_NAME"
spctl -a -t open --context context:primary-signature -v "Releases/$DMG_NAME"

step "Updating Releases/appcast.xml (committed locally; pushed last)"
# generate_appcast works on a folder holding only this release: older DMGs left in Releases/ would get their
# enclosure URLs rewritten to this tag (404) and deltas would be listed that are never uploaded.
APPCAST_DIR="$BUILD_DIR/appcast"
mkdir -p "$APPCAST_DIR"
cp "Releases/$DMG_NAME" "$APPCAST_DIR/"
[[ -f Releases/appcast.xml ]] && cp Releases/appcast.xml "$APPCAST_DIR/appcast.xml"
# Sparkle shows release notes from an HTML fragment beside the archive with the same base name; generate_appcast
# embeds it as the item's description (a --release-notes-url-prefix would instead link to <prefix><name>.html,
# which GitHub does not serve).
python3 Scripts/release-notes-html.py "$NOTES" "$APPCAST_DIR/${DMG_NAME%.dmg}.html"
# Signs with the EdDSA key from the Keychain. A pre-release goes to the "beta" channel so it is never offered
# to the users of the stable releases. (No empty-array expansion: macOS ships bash 3.2, where that trips `set -u`.)
if [[ "$PRERELEASE" == 1 ]]; then
  generate_appcast --maximum-deltas 0 --channel beta --download-url-prefix "$REPO_URL/releases/download/$TAG/" \
    --link "$REPO_URL/releases" -o "$APPCAST_DIR/appcast.xml" "$APPCAST_DIR"
else
  generate_appcast --maximum-deltas 0 --download-url-prefix "$REPO_URL/releases/download/$TAG/" \
    --link "$REPO_URL/releases" -o "$APPCAST_DIR/appcast.xml" "$APPCAST_DIR"
fi
# generate_appcast only warns when it cannot sign; an unsigned item would be refused by every installed copy.
python3 -I - "$APPCAST_DIR/appcast.xml" "$BUILD_NUMBER" <<'PY' || fail "the new appcast item for build $BUILD_NUMBER carries no sparkle:edSignature"
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
for item in re.findall(r"<item>.*?</item>", text, re.S):
    if re.search(r'sparkle:version(?:="|>)\s*%s\b' % re.escape(sys.argv[2]), item):
        sys.exit(0 if "sparkle:edSignature" in item else 1)
sys.exit(1)
PY
cp "$APPCAST_DIR/appcast.xml" Releases/appcast.xml
git add Releases/appcast.xml
git commit -q -m "release: appcast for $VERSION"

step "Creating GitHub release $TAG"
recover() {
  echo "error: the release stopped after the tag was pushed. Finish by hand:" >&2
  echo "  gh release create $TAG 'Releases/$DMG_NAME' --title '$PRODUCT_NAME for Mac $VERSION' --notes-file '$NOTES'$([[ "$PRERELEASE" == 1 ]] && echo ' --prerelease')" >&2
  echo "  git push origin HEAD    # publishes the appcast commit (only once the DMG is downloadable)" >&2
}
git tag -a "$TAG" -m "$PRODUCT_NAME for Mac $VERSION"
git push origin "$TAG"
trap recover ERR
if [[ "$PRERELEASE" == 1 ]]; then
  gh release create "$TAG" "Releases/$DMG_NAME" --title "$PRODUCT_NAME for Mac $VERSION" --notes-file "$NOTES" --prerelease
else
  gh release create "$TAG" "Releases/$DMG_NAME" --title "$PRODUCT_NAME for Mac $VERSION" --notes-file "$NOTES"
fi
git push origin HEAD
trap - ERR

echo
echo "Released $PRODUCT_NAME for Mac $VERSION: $REPO_URL/releases/tag/$TAG"
echo "Repo slug: $REPO_SLUG · appcast committed; Sparkle picks it up within ~5 minutes (raw.githubusercontent cache)."
