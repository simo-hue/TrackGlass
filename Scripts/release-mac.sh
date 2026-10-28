#!/bin/bash
# Trackglass for Mac release (SPEC §6.11, PLAN M11.2).
#
#   Scripts/release-mac.sh <version> [--pre-release] [--dry-run]
#
# archive → Developer ID export → DMG → notarytool submit --wait → stapler → GitHub release
# → generate_appcast → commit Releases/appcast.xml.
#
# One-time prerequisites on the release Mac (nothing here is stored in the repo):
#   • Developer ID Application certificate in the login Keychain; DEVELOPMENT_TEAM in Config/Local.xcconfig.
#   • Notarization credentials:  xcrun notarytool store-credentials "$TG_NOTARY_PROFILE"  (default profile name: trackglass-notary)
#   • Sparkle tools on PATH (generate_appcast; from the Sparkle release archive's bin/) and the EdDSA private key
#     in the Keychain, created with Sparkle's generate_keys. The public key is TG_SPARKLE_PUBLIC_KEY in Config/Local.xcconfig.
#   • gh auth login (GitHub CLI), and a release-notes file at Releases/release-notes/<version>.md.
#   • MARKETING_VERSION in Config/Shared.xcconfig must equal <version>.
#
# Guards: refuses a dirty working tree, an existing tag, a version mismatch, and a signing team that differs from
# the previously shipped app (SPEC §8.6, Scripts/assert-signing-team.sh). --dry-run stops before notarization.
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
MARKETING_VERSION="$(sed -n 's/^MARKETING_VERSION *= *//p' Config/Shared.xcconfig)"
DMG_NAME="$PRODUCT_NAME-for-Mac-$VERSION.dmg"
NOTES="Releases/release-notes/$VERSION.md"
BUILD_DIR="${TMPDIR:-/tmp}/trackglass-release-$VERSION"
ARCHIVE="$BUILD_DIR/TrackglassMac.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
STAGING="$BUILD_DIR/dmg-root"
PREVIOUS_APP="${TG_PREVIOUS_APP:-/Applications/$PRODUCT_NAME.app}"

step() { printf '\n==> %s\n' "$*"; }
fail() { echo "error: $*" >&2; exit 1; }

step "Checking prerequisites"
[[ -z "$(git status --porcelain)" ]] || fail "working tree is dirty; commit or stash first"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "tag $TAG already exists"
[[ "$MARKETING_VERSION" == "$VERSION" ]] || fail "MARKETING_VERSION is $MARKETING_VERSION, not $VERSION (edit Config/Shared.xcconfig)"
[[ -f "$NOTES" ]] || fail "missing release notes $NOTES"
[[ -f Config/Local.xcconfig ]] && grep -q '^DEVELOPMENT_TEAM *= *[A-Z0-9]' Config/Local.xcconfig || fail "DEVELOPMENT_TEAM is not set in Config/Local.xcconfig"
grep -q '^TG_SPARKLE_PUBLIC_KEY *= *[A-Za-z0-9+/=]' Config/Local.xcconfig || fail "TG_SPARKLE_PUBLIC_KEY is not set in Config/Local.xcconfig (Sparkle generate_keys)"
for tool in xcodegen xcodebuild hdiutil gh generate_appcast; do
  command -v "$tool" >/dev/null || fail "$tool is not on PATH"
done
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || fail "notarytool profile '$NOTARY_PROFILE' is missing (xcrun notarytool store-credentials)"
gh auth status >/dev/null 2>&1 || fail "gh is not authenticated (gh auth login)"
TEAM_ID="$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Config/Local.xcconfig | tr -d '[:space:]')"

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

step "Generating project and archiving $PRODUCT_NAME $VERSION"
xcodegen generate >/dev/null
xcodebuild -project Trackglass.xcodeproj -scheme TrackglassMac -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" archive | tail -3

step "Exporting with Developer ID"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$EXPORT_DIR" | tail -3
APP="$(find "$EXPORT_DIR" -maxdepth 1 -name '*.app' | head -1)"
[[ -d "$APP" ]] || fail "export produced no .app"
codesign --verify --deep --strict --verbose=2 "$APP"

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
codesign --force --sign "Developer ID Application" --timestamp "Releases/$DMG_NAME"

if [[ "$DRY_RUN" == 1 ]]; then
  echo "dry run: stopping before notarization. DMG at Releases/$DMG_NAME (not committed; Releases/*.dmg is ignored)."
  exit 0
fi

step "Notarizing (this waits for Apple)"
xcrun notarytool submit "Releases/$DMG_NAME" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "Releases/$DMG_NAME"
spctl -a -t open --context context:primary-signature -v "Releases/$DMG_NAME"

step "Creating GitHub release $TAG"
git tag -a "$TAG" -m "$PRODUCT_NAME for Mac $VERSION"
git push origin "$TAG"
# (no empty-array expansion: macOS ships bash 3.2, where that trips `set -u`)
if [[ "$PRERELEASE" == 1 ]]; then
  gh release create "$TAG" "Releases/$DMG_NAME" --title "$PRODUCT_NAME for Mac $VERSION" --notes-file "$NOTES" --prerelease
else
  gh release create "$TAG" "Releases/$DMG_NAME" --title "$PRODUCT_NAME for Mac $VERSION" --notes-file "$NOTES"
fi

step "Updating Releases/appcast.xml"
# generate_appcast signs with the EdDSA key from the Keychain and rewrites enclosure URLs to the release assets.
generate_appcast --download-url-prefix "$REPO_URL/releases/download/$TAG/" --link "$REPO_URL/releases" \
  --release-notes-url-prefix "$REPO_URL/releases/tag/" -o Releases/appcast.xml Releases/
git add Releases/appcast.xml
git commit -m "release: appcast for $VERSION"
git push origin HEAD

echo
echo "Released $PRODUCT_NAME for Mac $VERSION: $REPO_URL/releases/tag/$TAG"
echo "Repo slug: $REPO_SLUG · appcast committed; Sparkle picks it up within ~5 minutes (raw.githubusercontent cache)."
