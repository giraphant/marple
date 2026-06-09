#!/bin/bash
# One-shot: regenerate project, archive, sign, and upload to TestFlight via the
# App Store Connect API key. Bump CURRENT_PROJECT_VERSION in project.yml first.
# Secrets: apple/ios/.release.env (gitignored) + ~/.appstoreconnect/private_keys/AuthKey_<id>.p8
set -euo pipefail
cd "$(dirname "$0")"
source .release.env
KEY=~/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8
ARCH=/tmp/MarpleiOS.xcarchive
xcodegen generate >/dev/null
rm -rf "$ARCH" /tmp/marple-export
echo "▸ archiving…"
xcodebuild archive -project MarpleiOS.xcodeproj -scheme MarpleiOS \
  -archivePath "$ARCH" -destination 'generic/platform=iOS' -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  -quiet
echo "▸ exporting + uploading…"
cat > /tmp/MarpleExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>2E5N3Q45BG</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCH" -exportPath /tmp/marple-export \
  -exportOptionsPlist /tmp/MarpleExportOptions.plist -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID"
echo "✅ uploaded — TestFlight will show it after Apple finishes processing (~10-30 min)."
