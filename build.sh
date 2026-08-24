#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
DRIFT_SOURCE="${DRIFT_SOURCE:-/System/Library/ExtensionKit/Extensions/Drift.appex}"
OUTPUT_ROOT="${OUTPUT_ROOT:-$ROOT/build}"
PACKAGE_BASENAME="${PACKAGE_BASENAME:-Drift-Native-Clone-Dev2}"
EXTENSION_BUNDLE_ID="${EXTENSION_BUNDLE_ID:-com.brettbest.ScreenSaver.DriftNativeClone.Dev2.Extension}"
DISPLAY_NAME="${DISPLAY_NAME:-Drift (Both Displays)}"
APP_BASENAME="${APP_BASENAME:-Drift Both Displays Dev2}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.brettbest.ScreenSaver.DriftNativeClone.Dev2}"
OUTPUT_APP_ZIP="$OUTPUT_ROOT/$APP_BASENAME.app.zip"

if [[ ! -d "$DRIFT_SOURCE" ]]; then
    print -u2 "Apple Drift was not found at: $DRIFT_SOURCE"
    exit 2
fi

if [[ "$EXTENSION_BUNDLE_ID" != "$APP_BUNDLE_ID".* ]]; then
    print -u2 "extension bundle ID must begin with the containing app bundle ID"
    exit 2
fi

if [[ -e "$OUTPUT_APP_ZIP" ]]; then
    print -u2 "refusing to overwrite existing output: $OUTPUT_APP_ZIP"
    exit 3
fi

SDK="$(xcrun --show-sdk-path)"
MODULE_CACHE="$(mktemp -d /private/tmp/drift-native-modules.XXXXXX)"
BUILD_ROOT="$(mktemp -d /private/tmp/drift-native.XXXXXX)"

cleanup()
{
    rm -rf "$MODULE_CACHE" "$BUILD_ROOT"
}
trap cleanup EXIT

BUNDLE="$BUILD_ROOT/$PACKAGE_BASENAME.appex"
NESTED="$BUNDLE/Contents/Resources/DriftRenderer.bundle"
APP="$BUILD_ROOT/$APP_BASENAME.app"
EMBEDDED="$APP/Contents/PlugIns/$PACKAGE_BASENAME.appex"

mkdir -p \
    "$BUNDLE/Contents/MacOS" \
    "$BUNDLE/Contents/Resources" \
    "$NESTED/Contents/MacOS" \
    "$NESTED/Contents/Resources"

# Keep Apple's native screen-saver metadata, including its configuration
# controller. Only the clone identity and launcher name differ.
cp "$DRIFT_SOURCE/Contents/Info.plist" "$BUNDLE/Contents/Info.plist"
cp "$DRIFT_SOURCE/Contents/version.plist" "$BUNDLE/Contents/version.plist"
cp -R "$DRIFT_SOURCE/Contents/Resources/." "$BUNDLE/Contents/Resources/"
rm -f "$BUNDLE/Contents/Resources/InfoPlist.loctable"
plutil -replace CFBundleExecutable -string DriftNativeLauncher "$BUNDLE/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$EXTENSION_BUNDLE_ID" "$BUNDLE/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "$DISPLAY_NAME" "$BUNDLE/Contents/Info.plist"
plutil -replace CFBundleName -string "$DISPLAY_NAME" "$BUNDLE/Contents/Info.plist"

# Load the copied Drift implementation, install the screen-context correction,
# and then enter the normal native extension main loop.
xcrun clang \
    -arch arm64 \
    -fobjc-arc \
    -fmodules \
    -fobjc-exceptions \
    -fmodules-cache-path="$MODULE_CACHE" \
    -isysroot "$SDK" \
    -mmacosx-version-min=27.0 \
    -framework AppKit \
    -framework Foundation \
    -framework MetalKit \
    -framework ScreenSaver \
    -o "$BUNDLE/Contents/MacOS/DriftNativeLauncher" \
    "$ROOT/Sources/DriftCloneLoader.m" \
    "$ROOT/Sources/NativeMain.m"

# Convert the complete copied Apple executable into a private loadable bundle.
# Renderer instructions, resources, shaders, and configuration classes remain
# unchanged. Only the Mach-O type and PIE header fields required by NSBundle
# are modified.
cp "$DRIFT_SOURCE/Contents/Info.plist" "$NESTED/Contents/Info.plist"
cp "$DRIFT_SOURCE/Contents/version.plist" "$NESTED/Contents/version.plist"
cp -R "$DRIFT_SOURCE/Contents/Resources/." "$NESTED/Contents/Resources/"
lipo "$DRIFT_SOURCE/Contents/MacOS/Drift" \
    -thin arm64e \
    -output "$BUILD_ROOT/Drift-arm64e"
lipo "$DRIFT_SOURCE/Contents/MacOS/Drift" \
    -thin x86_64 \
    -output "$BUILD_ROOT/Drift-x86_64"
python3 "$ROOT/scripts/patch_header.py" "$BUILD_ROOT/Drift-arm64e"
python3 "$ROOT/scripts/patch_header.py" "$BUILD_ROOT/Drift-x86_64"
lipo -create \
    -output "$NESTED/Contents/MacOS/Drift" \
    "$BUILD_ROOT/Drift-arm64e" \
    "$BUILD_ROOT/Drift-x86_64"
chmod 755 "$NESTED/Contents/MacOS/Drift"

rm -f "$NESTED/Contents/Resources/InfoPlist.loctable"
plutil -replace CFBundlePackageType -string BNDL "$NESTED/Contents/Info.plist"
plutil -replace CFBundleIdentifier \
    -string "$EXTENSION_BUNDLE_ID.Renderer" \
    "$NESTED/Contents/Info.plist"
plutil -replace CFBundleDisplayName \
    -string "Drift Complete Apple Renderer" \
    "$NESTED/Contents/Info.plist"
plutil -replace CFBundleName \
    -string "Drift Complete Apple Renderer" \
    "$NESTED/Contents/Info.plist"
plutil -insert NSPrincipalClass -string "Drift.FlowView" "$NESTED/Contents/Info.plist"
plutil -insert CFBundleSignature -string "????" "$NESTED/Contents/Info.plist"
plutil -remove NSExtension "$NESTED/Contents/Info.plist"
plutil -remove NSExtensionContextClass "$NESTED/Contents/Info.plist"
plutil -remove ScreenSaverViewControllerClass "$NESTED/Contents/Info.plist"
plutil -remove ScreenSaverConfigurationSheetViewControllerClass "$NESTED/Contents/Info.plist"
plutil -remove SSEHasConfigureSheet "$NESTED/Contents/Info.plist"

xattr -cr "$BUNDLE" 2>/dev/null || true
codesign --force --sign - "$NESTED"
codesign --force --deep --sign - \
    --entitlements "$ROOT/Configuration/ExtensionEntitlements.plist" \
    "$BUNDLE"
codesign --verify --deep --strict "$BUNDLE"

# PlugInKit discovers a user ExtensionKit extension through a containing app.
# This app has no UI or background behavior; it only provides that container.
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/PlugIns"
cp "$ROOT/Configuration/ContainerInfo.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "$APP_BASENAME" "$APP/Contents/Info.plist"
plutil -replace CFBundleName -string "$APP_BASENAME" "$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$APP_BUNDLE_ID" "$APP/Contents/Info.plist"
xcrun clang \
    -arch arm64 \
    -fobjc-arc \
    -fmodules \
    -fmodules-cache-path="$MODULE_CACHE" \
    -isysroot "$SDK" \
    -mmacosx-version-min=27.0 \
    -framework Foundation \
    -o "$APP/Contents/MacOS/DriftNativeContainer" \
    "$ROOT/Sources/ContainerMain.m"
ditto --norsrc "$BUNDLE" "$EMBEDDED"
xattr -cr "$APP" 2>/dev/null || true
codesign --force --sign - "$EMBEDDED/Contents/Resources/DriftRenderer.bundle"
codesign --force --deep --sign - \
    --entitlements "$ROOT/Configuration/ExtensionEntitlements.plist" \
    "$EMBEDDED"
codesign --force --deep --sign - \
    --entitlements "$ROOT/Configuration/ContainerEntitlements.plist" \
    "$APP"
codesign --verify --deep --strict "$APP"

mkdir -p "$OUTPUT_ROOT"
ditto -c -k --norsrc --keepParent "$APP" "$OUTPUT_APP_ZIP"

echo "OUTPUT_APP_ZIP=$OUTPUT_APP_ZIP"
echo "APP_SHA256=$(shasum -a 256 "$OUTPUT_APP_ZIP" | awk '{print $1}')"
