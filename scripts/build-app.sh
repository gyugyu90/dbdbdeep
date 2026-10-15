#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
TASK_JAVA="$(/usr/libexec/java_home -v 21)"
TASK_DRIVER_VERSION="23.26.3.0.0"
TASK_ORACLE="$TASK_ROOT/.oracle"
TASK_APP="${DBDBDEEP_APP_OUTPUT:-$TASK_ROOT/build/dbdbdeep.app}"
TASK_BUNDLE_ID="${DBDBDEEP_BUNDLE_ID:-studio.dbdbdeep.app}"
mkdir -p "$TASK_ORACLE/classes" "$TASK_ROOT/build"
download_oracle_jar() {
    local artifact="$1" group="$2"
    local target="$TASK_ORACLE/$artifact.jar"
    local base="https://repo.maven.apache.org/maven2/com/oracle/database/$group/$artifact/$TASK_DRIVER_VERSION/$artifact-$TASK_DRIVER_VERSION.jar"
    if [ ! -s "$target" ]; then
        curl --fail --location --retry 2 "$base" -o "$target.download"
        curl --fail --location --retry 2 "$base.sha256" -o "$target.sha256"
        local expected actual
        expected="$(tr -d '[:space:]' < "$target.sha256")"
        actual="$(shasum -a 256 "$target.download" | cut -d ' ' -f 1)"
        if [ "$expected" != "$actual" ]; then
            echo "Oracle $artifact checksum mismatch." >&2
            exit 1
        fi
        mv "$target.download" "$target"
    fi
}
download_oracle_jar ojdbc11 jdbc
download_oracle_jar orai18n nls
"$TASK_JAVA/bin/javac" -d "$TASK_ORACLE/classes" OracleBridge/OracleBridge.java
TASK_CLASSPATH="$TASK_ORACLE/classes:$TASK_ORACLE/ojdbc11.jar:$TASK_ORACLE/orai18n.jar"
"$TASK_JAVA/bin/java" -cp "$TASK_CLASSPATH" OracleBridge --self-test
if [ ! -x "$TASK_ORACLE/jre/bin/java" ] || ! "$TASK_ORACLE/jre/bin/java" --list-modules | grep -q '^jdk.charsets@'; then
    TASK_NEW_JRE="$TASK_ORACLE/jre-next"
    if [ -e "$TASK_NEW_JRE" ]; then
        echo "Remove the incomplete .oracle/jre-next directory before retrying." >&2
        exit 1
    fi
    "$TASK_JAVA/bin/jlink" --add-modules java.base,java.sql,java.naming,java.management,java.security.jgss,java.xml,jdk.crypto.ec,jdk.unsupported,jdk.charsets --strip-debug --no-man-pages --no-header-files --compress=zip-6 --output "$TASK_NEW_JRE"
    if [ -d "$TASK_ORACLE/jre" ]; then mv "$TASK_ORACLE/jre" "$TASK_ORACLE/jre-previous-$(date +%s)"; fi
    mv "$TASK_NEW_JRE" "$TASK_ORACLE/jre"
fi
"$TASK_ORACLE/jre/bin/java" -cp "$TASK_CLASSPATH" OracleBridge --charset-self-test
swift build -c release
swift scripts/make-icon.swift "$TASK_ROOT/build/AppIcon.iconset"
iconutil -c icns "$TASK_ROOT/build/AppIcon.iconset" -o "$TASK_ROOT/build/AppIcon.icns"
swift scripts/make-icon.swift "$TASK_ROOT/build/AppIconDark.iconset" --dark
iconutil -c icns "$TASK_ROOT/build/AppIconDark.iconset" -o "$TASK_ROOT/build/AppIconDark.icns"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources/Oracle"
cp "$TASK_ROOT/build/AppIcon.icns" "$TASK_APP/Contents/Resources/"
cp "$TASK_ROOT/build/AppIconDark.icns" "$TASK_APP/Contents/Resources/"
cp .build/release/dbdbdeep "$TASK_APP/Contents/MacOS/dbdbdeep"
cp "$TASK_ORACLE/ojdbc11.jar" "$TASK_ORACLE/orai18n.jar" "$TASK_APP/Contents/Resources/Oracle/"
cp -R "$TASK_ORACLE/classes" "$TASK_APP/Contents/Resources/Oracle/"
ditto "$TASK_ORACLE/jre" "$TASK_APP/Contents/Resources/Oracle/jre"
cat > "$TASK_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>dbdbdeep</string>
<key>CFBundleDisplayName</key><string>dbdbdeep</string>
<key>CFBundleIdentifier</key><string>studio.dbdbdeep.app</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>dbdbdeep</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $TASK_BUNDLE_ID" "$TASK_APP/Contents/Info.plist"
codesign --force --deep --sign - "$TASK_APP"
echo "Built: $TASK_APP"
