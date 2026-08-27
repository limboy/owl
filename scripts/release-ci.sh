#!/bin/bash
set -euo pipefail

# Build, sign, notarize, and Sparkle-sign an Owl DMG on GitHub Actions.
# The tag-triggered workflow publishes build/Owl.dmg and build/appcast.xml.

VERSION="${1:?Usage: bash scripts/release-ci.sh <version>}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "❌ Invalid release version: $VERSION"
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

required_secrets=(
  APPLE_TEAM_ID
  ASC_ISSUER_ID
  ASC_KEY_ID
  ASC_PRIVATE_KEY
  MACOS_CERTIFICATE_P12_BASE64
  SIGNING_IDENTITY_NAME
  SPARKLE_ED_PRIVATE_KEY
)
for name in "${required_secrets[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    echo "❌ Required secret $name is missing or empty"
    exit 1
  fi
done

for command in xcodegen create-dmg xcodebuild security codesign xcrun gh; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "❌ Required command is unavailable: $command"
    exit 1
  fi
done

if [[ "${GITHUB_REF_NAME:-v$VERSION}" != "v$VERSION" ]]; then
  echo "❌ Tag ${GITHUB_REF_NAME:-<none>} does not match version $VERSION"
  exit 1
fi

CERTIFICATE_PATH="$RUNNER_TEMP/Certificates.p12"
ASC_KEY_PATH="$RUNNER_TEMP/AuthKey_${ASC_KEY_ID}.p8"
KEYCHAIN_PATH="$RUNNER_TEMP/owl-release.keychain-db"
KEYCHAIN_PASSWORD="$(uuidgen)"
SIGNING_IDENTITY="Developer ID Application: $SIGNING_IDENTITY_NAME ($APPLE_TEAM_ID)"

cleanup() {
  security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
  rm -f "$CERTIFICATE_PATH" "$ASC_KEY_PATH"
}
trap cleanup EXIT

umask 077
printf '%s' "$MACOS_CERTIFICATE_P12_BASE64" |
  openssl base64 -d -A -out "$CERTIFICATE_PATH"
printf '%s' "$ASC_PRIVATE_KEY" > "$ASC_KEY_PATH"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$CERTIFICATE_PATH" \
  -k "$KEYCHAIN_PATH" \
  -P "${MACOS_CERTIFICATE_PASSWORD:-}" \
  -A \
  -t cert \
  -f pkcs12
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "$KEYCHAIN_PASSWORD" \
  "$KEYCHAIN_PATH" >/dev/null
security list-keychains -d user -s "$KEYCHAIN_PATH"
security default-keychain -d user -s "$KEYCHAIN_PATH"

if ! security find-identity -v -p codesigning "$KEYCHAIN_PATH" |
  grep -Fq "$SIGNING_IDENTITY"; then
  echo "❌ Expected signing identity was not imported: $SIGNING_IDENTITY"
  exit 1
fi

echo "🔨 Building Owl v$VERSION..."
xcodegen generate

echo "📦 Vendoring libmpv/ffmpeg..."
scripts/bundle-mpv-deps.sh

rm -rf build
mkdir -p build

authentication_args=(
  -allowProvisioningUpdates
  -authenticationKeyPath "$ASC_KEY_PATH"
  -authenticationKeyID "$ASC_KEY_ID"
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
)

xcodebuild \
  -project Owl.xcodeproj \
  -scheme Owl \
  -configuration Release \
  -archivePath build/Owl.xcarchive \
  archive \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$VERSION" \
  TMDB_API_KEY="${TMDB_API_KEY:-}"

sed "s/\${APPLE_TEAM_ID}/$APPLE_TEAM_ID/g" \
  ExportOptions.plist > build/ExportOptions.plist
xcodebuild \
  -exportArchive \
  -archivePath build/Owl.xcarchive \
  -exportOptionsPlist build/ExportOptions.plist \
  -exportPath build/export

echo "🔍 Verifying code signature..."
scripts/verify-entitlements.sh build/export/Owl.app
codesign --verify --deep --strict --verbose=2 build/export/Owl.app

notary_args=(
  --key "$ASC_KEY_PATH"
  --key-id "$ASC_KEY_ID"
  --issuer "$ASC_ISSUER_ID"
  --wait
  --output-format json
)

echo "🔏 Notarizing and stapling Owl.app..."
ditto \
  -c \
  -k \
  --keepParent \
  build/export/Owl.app \
  build/Owl-notarization.zip
xcrun notarytool submit \
  build/Owl-notarization.zip \
  "${notary_args[@]}" |
  tee build/notarization-app.json
if [[ "$(plutil -extract status raw build/notarization-app.json)" != "Accepted" ]]; then
  echo "❌ App notarization was not accepted"
  exit 1
fi
xcrun stapler staple build/export/Owl.app
xcrun stapler validate build/export/Owl.app

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

  if [[ ! -f "$output_path" ]]; then
    echo "❌ DMG creation failed"
    exit 1
  fi
}

echo "📦 Creating, notarizing, and stapling Owl.dmg..."
create_owl_dmg build/Owl.dmg
xcrun notarytool submit \
  build/Owl.dmg \
  "${notary_args[@]}" |
  tee build/notarization-dmg.json
if [[ "$(plutil -extract status raw build/notarization-dmg.json)" != "Accepted" ]]; then
  echo "❌ DMG notarization was not accepted"
  exit 1
fi
xcrun stapler staple build/Owl.dmg
xcrun stapler validate build/Owl.dmg

spctl --assess --type execute --verbose build/export/Owl.app
hdiutil verify build/Owl.dmg

SPARKLE_BIN="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
  -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update' \
  -type f \
  -print \
  -quit)"
if [[ -z "$SPARKLE_BIN" ]]; then
  echo "❌ Sparkle sign_update was not found in DerivedData"
  exit 1
fi

echo "✍️ Signing the DMG for Sparkle..."
signature_output="$(
  printf '%s' "$SPARKLE_ED_PRIVATE_KEY" |
    "$SPARKLE_BIN" --ed-key-file - build/Owl.dmg
)"
ed_signature="$(
  printf '%s' "$signature_output" |
    sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p'
)"
signed_length="$(
  printf '%s' "$signature_output" |
    sed -n 's/.*length="\([^"]*\)".*/\1/p'
)"
actual_length="$(stat -f '%z' build/Owl.dmg)"
if [[ -z "$ed_signature" || "$signed_length" != "$actual_length" ]]; then
  echo "❌ Sparkle signature metadata is invalid"
  exit 1
fi

extract_changelog_markdown() {
  awk -v version="$VERSION" '
    $0 ~ "^## \\[" version "\\]" { capture=1; next }
    capture && /^## / { exit }
    capture && /^- / { print }
  ' CHANGELOG.md
}

release_notes="$(extract_changelog_markdown)"
if [[ -z "$release_notes" ]]; then
  echo "❌ CHANGELOG.md has no release notes for v$VERSION"
  exit 1
fi
printf '%s\n' "$release_notes" > build/release-notes.md

html_notes="<ul>"
while IFS= read -r line; do
  item="${line#- }"
  item="${item//&/&amp;}"
  item="${item//</&lt;}"
  item="${item//>/&gt;}"
  html_notes+="<li>$item</li>"
done <<< "$release_notes"
html_notes+="</ul>"

pub_date="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"
repository="${GITHUB_REPOSITORY:-limboy/owl}"

cat > build/appcast.xml <<APPCAST
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0">
  <channel>
    <title>Owl</title>
    <item>
      <title>Version $VERSION</title>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <pubDate>$pub_date</pubDate>
      <description><![CDATA[$html_notes]]></description>
      <enclosure
        url="https://github.com/$repository/releases/download/v$VERSION/Owl.dmg"
        sparkle:edSignature="$ed_signature"
        length="$actual_length"
        type="application/octet-stream"
      />
    </item>
  </channel>
</rss>
APPCAST

plutil -lint build/export/Owl.app/Contents/Info.plist
echo "✅ Owl v$VERSION is ready at build/Owl.dmg"
