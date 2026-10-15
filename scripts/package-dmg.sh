#!/bin/bash
set -euo pipefail

TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_APP="${1:-$TASK_ROOT/build/dbdbdeep.app}"

if [ ! -d "$TASK_APP" ]; then
    echo "Build the app first with ./scripts/build-app.sh." >&2
    exit 1
fi

codesign --verify --deep --strict "$TASK_APP"
TASK_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TASK_APP/Contents/Info.plist")"
TASK_ARCH="$(lipo -archs "$TASK_APP/Contents/MacOS/dbdbdeep" | tr ' ' '-')"
TASK_OUTPUT="${2:-$TASK_ROOT/build/dbdbdeep-$TASK_VERSION-macos-$TASK_ARCH.dmg}"

if [ -e "$TASK_OUTPUT" ]; then
    echo "Output already exists: $TASK_OUTPUT" >&2
    exit 1
fi

mkdir -p "$TASK_ROOT/build"
TASK_STAGING="$(mktemp -d "$TASK_ROOT/build/dmg-stage.XXXXXX")"
TASK_CONTENTS="$TASK_STAGING/contents"
TASK_MOUNT="$TASK_STAGING/mount"
TASK_WORK="$TASK_STAGING/installer.dmg"
mkdir -p "$TASK_CONTENTS" "$TASK_MOUNT"

ditto --norsrc --noextattr --noacl "$TASK_APP" "$TASK_CONTENTS/dbdbdeep.app"
codesign --verify --deep --strict "$TASK_CONTENTS/dbdbdeep.app"
ln -s /Applications "$TASK_CONTENTS/Applications"
cat > "$TASK_CONTENTS/Install.txt" <<'TEXT'
Welcome to dbdbdeep!

1. Drag dbdbdeep.app into Applications.
2. Open dbdbdeep from Applications.
3. Eject this disk image when you're done.

Java and the Oracle drivers are included.
This build is locally signed and has not been notarized by Apple.
TEXT

mkdir -p "$(dirname "$TASK_OUTPUT")"
hdiutil create -volname "dbdbdeep $TASK_VERSION" -srcfolder "$TASK_CONTENTS" -format UDRW -fs APFS "$TASK_WORK"
hdiutil attach -nobrowse -mountpoint "$TASK_MOUNT" "$TASK_WORK"
trap 'hdiutil detach "$TASK_MOUNT" >/dev/null 2>&1 || true' EXIT
chmod -R u+w "$TASK_MOUNT/dbdbdeep.app"
xattr -cr "$TASK_MOUNT/dbdbdeep.app"
codesign --verify --deep --strict "$TASK_MOUNT/dbdbdeep.app"
hdiutil detach "$TASK_MOUNT"
trap - EXIT
hdiutil convert "$TASK_WORK" -format UDZO -o "$TASK_OUTPUT"
hdiutil verify "$TASK_OUTPUT"
echo "Packaged: $TASK_OUTPUT"
