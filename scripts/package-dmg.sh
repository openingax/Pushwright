#!/bin/bash
# Builds a Release Pushwright.app and packs it into dist/Pushwright-<version>.dmg.
#
# With a "Developer ID Application" identity in the keychain, the app and the DMG are signed for distribution.
# Without one, the DMG holds the archive's development-signed app, which runs on this Mac but is blocked by
# Gatekeeper on others.
#
# Set NOTARY_PROFILE to notarize and staple the DMG. Save the profile once with:
#   xcrun notarytool store-credentials <profile> --apple-id <you@example.com> --team-id <TEAMID>
set -euo pipefail

cd "$(dirname "$0")/.."
DIST=dist
ARCHIVE=$DIST/Pushwright.xcarchive
STAGE=$DIST/dmg-root
rm -rf "$ARCHIVE" "$DIST/export" "$STAGE"
mkdir -p "$DIST"

xcodebuild archive -quiet \
    -project App/Pushwright.xcodeproj -scheme Pushwright \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE"

IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')
if [[ -n $IDENTITY ]]; then
    OPTIONS=$DIST/ExportOptions.plist
    cat > "$OPTIONS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>method</key><string>developer-id</string></dict></plist>
PLIST
    xcodebuild -exportArchive -quiet \
        -archivePath "$ARCHIVE" -exportPath "$DIST/export" -exportOptionsPlist "$OPTIONS"
    APP=$DIST/export/Pushwright.app
else
    echo "warning: no Developer ID Application identity; the DMG is for this Mac only." >&2
    APP=$ARCHIVE/Products/Applications/Pushwright.app
fi
codesign --verify --deep --strict "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG=$DIST/Pushwright-$VERSION.dmg
mkdir "$STAGE"
ditto "$APP" "$STAGE/Pushwright.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -ov -volname Pushwright -srcfolder "$STAGE" -format UDZO "$DMG"
rm -rf "$STAGE"

if [[ -n $IDENTITY ]]; then
    codesign --sign "$IDENTITY" --timestamp "$DMG"
fi

if [[ -n ${NOTARY_PROFILE:-} ]]; then
    if [[ -z $IDENTITY ]]; then
        echo "error: notarization needs a Developer ID Application identity." >&2
        exit 1
    fi
    RESULT=$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)
    STATUS=$(plutil -extract status raw -o - - <<< "$RESULT")
    if [[ $STATUS != Accepted ]]; then
        ID=$(plutil -extract id raw -o - - <<< "$RESULT")
        echo "error: notarization finished as $STATUS. Details: xcrun notarytool log $ID --keychain-profile $NOTARY_PROFILE" >&2
        exit 1
    fi
    xcrun stapler staple -q "$DMG"
fi

echo "$DMG"
shasum -a 256 "$DMG"
