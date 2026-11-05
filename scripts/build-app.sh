#!/bin/zsh
# Builds build/Flyers.app. Signs ad hoc unless FLYERS_SIGN_IDENTITY names a certificate.
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release --product Flyers
binary_dir="$(swift build -c release --show-bin-path)"

app=build/Flyers.app
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp "$binary_dir/Flyers" "$app/Contents/MacOS/Flyers"
# SwiftPM records the deployment target (macOS 15) as the SDK version, which makes AppKit run the
# app in compatibility mode with no Liquid Glass. Record the real SDK it was built with.
vtool -set-build-version macos 15.0 "$(xcrun --show-sdk-version)" -replace \
    -output "$app/Contents/MacOS/Flyers" "$app/Contents/MacOS/Flyers"
printf 'APPL????' > "$app/Contents/PkgInfo"

codesign --force --sign "${FLYERS_SIGN_IDENTITY:--}" "$app"
echo "Built $PWD/$app"
