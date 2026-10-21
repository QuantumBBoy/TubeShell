#!/bin/bash
# Builds TubeShell.ipa without signing it, for SideStore / AltStore
# (they sign it with your own Apple ID and renew it every week).
#
# Usage, from this folder on the Mac:   ./make_ipa.sh
set -euo pipefail
cd "$(dirname "$0")"

# Its own folders under build/, so renew.sh's build there is left alone.
rm -rf build/ipa-dd build/ipa TubeShell.ipa

xcodebuild \
  -project TubeShell.xcodeproj \
  -scheme TubeShell \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/ipa-dd \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

mkdir -p build/ipa/Payload
cp -R build/ipa-dd/Build/Products/Release-iphoneos/TubeShell.app build/ipa/Payload/
(cd build/ipa && zip -qry ../../TubeShell.ipa Payload)

echo ""
echo "Listo: $(pwd)/TubeShell.ipa"
echo "Pásalo al iPhone (AirDrop o Archivos) y ábrelo con SideStore o AltStore."
