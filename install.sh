#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
APP_BASENAME="${APP_BASENAME:-Drift Both Displays Dev2}"
PACKAGE_BASENAME="${PACKAGE_BASENAME:-Drift-Native-Clone-Dev2}"
EXTENSION_BUNDLE_ID="${EXTENSION_BUNDLE_ID:-com.brettbest.ScreenSaver.DriftNativeClone.Dev2.Extension}"
ARCHIVE="${ARCHIVE:-$ROOT/build/$APP_BASENAME.app.zip}"
INSTALL_ROOT="${INSTALL_ROOT:-$HOME/Applications}"
DESTINATION="$INSTALL_ROOT/$APP_BASENAME.app"
LAUNCH_SERVICES_REGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ ! -f "$ARCHIVE" ]]; then
    print -u2 "build archive not found: $ARCHIVE"
    print -u2 "run ./build.sh first"
    exit 2
fi

if [[ -e "$DESTINATION" ]]; then
    print -u2 "refusing to overwrite existing installation: $DESTINATION"
    exit 3
fi

EXTRACT_ROOT="$(mktemp -d /private/tmp/drift-install.XXXXXX)"
cleanup()
{
    rm -rf "$EXTRACT_ROOT"
}
trap cleanup EXIT

ditto -x -k "$ARCHIVE" "$EXTRACT_ROOT"
SOURCE_APP="$EXTRACT_ROOT/$APP_BASENAME.app"
if [[ ! -d "$SOURCE_APP" ]]; then
    print -u2 "archive does not contain the expected app: $APP_BASENAME.app"
    exit 4
fi

codesign --verify --deep --strict "$SOURCE_APP"
mkdir -p "$INSTALL_ROOT"
ditto --norsrc "$SOURCE_APP" "$DESTINATION"
xattr -cr "$DESTINATION"
codesign --verify --deep --strict "$DESTINATION"

"$LAUNCH_SERVICES_REGISTER" -f "$DESTINATION"
EMBEDDED="$DESTINATION/Contents/PlugIns/$PACKAGE_BASENAME.appex"
pluginkit -a "$EMBEDDED"
sleep 2
pluginkit -m -A -D -v -i "$EXTENSION_BUNDLE_ID"

echo "INSTALLED_APP=$DESTINATION"
