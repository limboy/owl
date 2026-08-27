#!/bin/bash
set -euo pipefail

# Usage: ./scripts/release.sh [--dry-run] 1.0.0
#
# Options:
#   --dry-run  Build, sign, and verify only. Skips notarization, GitHub, and appcast.
#
# Reads credentials from .env in the project root.
# See .env.example for required variables:
#   APPLE_TEAM_ID          — Apple Developer Team ID
#   APPLE_ID                — Apple ID email for notarization
#   SIGNING_IDENTITY_NAME   — e.g. "Your Name" or "Your Company, LLC"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

if [ -f "$ROOT_DIR/.env" ]; then
  set -a
  source "$ROOT_DIR/.env"
  set +a
fi

DRY_RUN=false
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=true
  shift
fi

VERSION="${1:?Usage: ./scripts/release.sh [--dry-run] <version>}"
REPOSITORY="${GITHUB_REPOSITORY:-limboy/owl}"
# Names the Keychain item holding the Sparkle EdDSA private key. It keeps the
# old "mvplayer" name on purpose: the key itself did not change when the app was
# renamed, and SUPublicEDKey still has to match it. Rename it here only after
# renaming the Keychain item to match.
SPARKLE_ACCOUNT="mvplayer"

# Extract changelog entries for a version and convert to HTML <ul>
extract_changelog() {
  local version="$1"
  local changelog="$2"
  local in_section=false
  local html="<ul>"

  while IFS= read -r line; do
    if [[ "$line" =~ ^##\ \[${version}\] ]]; then
      in_section=true
      continue
    fi
    if $in_section && [[ "$line" =~ ^##\  ]]; then
      break
    fi
    if $in_section && [[ "$line" =~ ^-\ (.+) ]]; then
      html+="<li>${BASH_REMATCH[1]}</li>"
    fi
  done < "$changelog"

  html+="</ul>"
  if [ "$html" = "<ul></ul>" ]; then
    echo ""
  else
    echo "$html"
  fi
}

# Extract raw markdown changelog entries for a version
extract_changelog_markdown() {
  local version="$1"
  local changelog="$2"
  local in_section=false
  local md=""

  while IFS= read -r line; do
    if [[ "$line" =~ ^##\ \[${version}\] ]]; then
      in_section=true
      continue
    fi
    if $in_section && [[ "$line" =~ ^##\  ]]; then
      break
    fi
    if $in_section && [[ "$line" =~ ^-\ (.+) ]]; then
      md+="- ${BASH_REMATCH[1]}"$'\n'
    fi
  done < "$changelog"

  echo "$md"
}

# Create a plain DMG with app icon and Applications drop link
create_owl_dmg() {
  local output_path="$1"
  rm -f "$output_path"

  create-dmg \
    --volname "Owl" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 160 \
    --text-size 14 \
    --icon "Owl.app" 170 180 \
    --hide-extension "Owl.app" \
    --app-drop-link 490 180 \
    --no-internet-enable \
    --format UDZO \
    "$output_path" \
    build/export/Owl.app || true

  [ -f "$output_path" ] || { echo "❌ DMG creation failed"; exit 1; }
}

TEAM_ID="${APPLE_TEAM_ID:?Set APPLE_TEAM_ID in .env}"
SIGNING_IDENTITY="Developer ID Application: ${SIGNING_IDENTITY_NAME:?Set SIGNING_IDENTITY_NAME in .env} ($TEAM_ID)"
APPLE_ID="${APPLE_ID:?Set APPLE_ID in .env}"

if ! $DRY_RUN; then
  if ! command -v create-dmg &>/dev/null; then
    echo "❌ create-dmg not found. Install with: brew install create-dmg"
    exit 1
  fi

  if ! xcrun notarytool history --keychain-profile "AC_PASSWORD" >/dev/null 2>&1; then
    echo "❌ Unable to use notarytool keychain profile \"AC_PASSWORD\"."
    echo "Create or refresh it with:"
    echo "  xcrun notarytool store-credentials \"AC_PASSWORD\" --apple-id \"$APPLE_ID\" --team-id \"$TEAM_ID\" --password \"<app-specific-password>\""
    exit 1
  fi
fi

echo "🔨 Building Owl v$VERSION..."

# Generate Xcode project
xcodegen generate

# Vendor libmpv/ffmpeg so the built app doesn't need Homebrew at runtime
echo "📦 Vendoring libmpv/ffmpeg..."
scripts/bundle-mpv-deps.sh

# Clean build
rm -rf build
mkdir -p build

# Archive
xcodebuild -project Owl.xcodeproj \
  -scheme Owl \
  -configuration Release \
  -archivePath build/Owl.xcarchive \
  archive \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$VERSION" \
  TMDB_API_KEY="${TMDB_API_KEY:-}"

# Export
sed "s/\${APPLE_TEAM_ID}/$TEAM_ID/g" ExportOptions.plist > build/ExportOptions.plist
xcodebuild -exportArchive \
  -archivePath build/Owl.xcarchive \
  -exportOptionsPlist build/ExportOptions.plist \
  -exportPath build/export

echo "🔍 Verifying code signature..."
scripts/verify-entitlements.sh build/export/Owl.app
codesign --verify --deep --strict build/export/Owl.app
echo "✅ Code signature verified (deep + strict)."

if $DRY_RUN; then
  echo "🏁 Dry run complete. Signed app at: build/export/Owl.app"
  echo "   To inspect: codesign -d --entitlements :- build/export/Owl.app"
  echo "   Note: spctl --assess will fail until notarized (expected in dry-run)."
  exit 0
fi

echo "📦 Creating DMG..."
create_owl_dmg build/Owl.dmg

echo "🔏 Notarizing..."
xcrun notarytool submit build/Owl.dmg \
  --keychain-profile "AC_PASSWORD" \
  --wait

echo "📎 Stapling..."
xcrun stapler staple build/export/Owl.app
rm build/Owl.dmg
create_owl_dmg build/Owl.dmg
xcrun stapler staple build/Owl.dmg || echo "⚠️  DMG staple failed (normal — CDN propagation delay). App inside is stapled."

# Gatekeeper assessment (must run after notarization + stapling)
spctl --assess --type execute --verbose build/export/Owl.app
echo "✅ Gatekeeper assessment passed."

echo "🏷️  Tagging v$VERSION..."
git tag "v$VERSION"
git push --tags

echo "📡 Generating Sparkle appcast..."
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData/Owl-*/SourcePackages/artifacts/sparkle/Sparkle/bin -maxdepth 0 2>/dev/null | head -1)
SIGNATURE=$("$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" build/Owl.dmg 2>&1)
ED_SIG=$(echo "$SIGNATURE" | grep -o 'sparkle:edSignature="[^"]*"' | cut -d'"' -f2)
LENGTH=$(echo "$SIGNATURE" | grep -o 'length="[^"]*"' | cut -d'"' -f2)
PUB_DATE=$(date -u +"%a, %d %b %Y %H:%M:%S +0000")

# Extract release notes from CHANGELOG.md
RELEASE_NOTES=$(extract_changelog "$VERSION" "CHANGELOG.md")
if [ -z "$RELEASE_NOTES" ]; then
  echo "⚠️  No changelog entry for v$VERSION in CHANGELOG.md. Appcast will have no release notes."
fi

# Build description element if we have release notes
DESC_ELEMENT=""
if [ -n "$RELEASE_NOTES" ]; then
  DESC_ELEMENT="      <description><![CDATA[$RELEASE_NOTES]]></description>"
fi

cat > build/appcast.xml << APPCAST
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0">
  <channel>
    <title>Owl</title>
    <item>
      <title>Version $VERSION</title>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <pubDate>$PUB_DATE</pubDate>
$DESC_ELEMENT
      <enclosure
        url="https://github.com/$REPOSITORY/releases/download/v$VERSION/Owl.dmg"
        sparkle:edSignature="$ED_SIG"
        length="$LENGTH"
        type="application/octet-stream"
      />
    </item>
  </channel>
</rss>
APPCAST

echo "🚀 Creating GitHub Release..."
CHANGELOG_MD=$(extract_changelog_markdown "$VERSION" "CHANGELOG.md")
if [ -n "$CHANGELOG_MD" ]; then
  gh release create "v$VERSION" build/Owl.dmg build/appcast.xml \
    --repo "$REPOSITORY" \
    --title "Owl v$VERSION" \
    --notes "$CHANGELOG_MD"
else
  gh release create "v$VERSION" build/Owl.dmg build/appcast.xml \
    --repo "$REPOSITORY" \
    --title "Owl v$VERSION" \
    --generate-notes
fi

echo "✅ Done! Release: https://github.com/$REPOSITORY/releases/tag/v$VERSION"
