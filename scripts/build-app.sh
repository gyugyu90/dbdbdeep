#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
TASK_JAVA="$(/usr/libexec/java_home -v 21)"
TASK_DRIVER_VERSION="23.26.3.0.0"
TASK_ORACLE="$TASK_ROOT/.oracle"
TASK_APP="$TASK_ROOT/build/dbdbdeep.app"
mkdir -p "$TASK_ORACLE/classes" "$TASK_ROOT/build"
if [ ! -s "$TASK_ORACLE/ojdbc11.jar" ]; then
    curl --fail --location --retry 2 "https://repo.maven.apache.org/maven2/com/oracle/database/jdbc/ojdbc11/$TASK_DRIVER_VERSION/ojdbc11-$TASK_DRIVER_VERSION.jar" -o "$TASK_ORACLE/ojdbc11.jar.download"
    curl --fail --location --retry 2 "https://repo.maven.apache.org/maven2/com/oracle/database/jdbc/ojdbc11/$TASK_DRIVER_VERSION/ojdbc11-$TASK_DRIVER_VERSION.jar.sha256" -o "$TASK_ORACLE/ojdbc11.sha256"
    TASK_EXPECTED="$(tr -d '[:space:]' < "$TASK_ORACLE/ojdbc11.sha256")"
    TASK_ACTUAL="$(shasum -a 256 "$TASK_ORACLE/ojdbc11.jar.download" | cut -d ' ' -f 1)"
    if [ "$TASK_EXPECTED" != "$TASK_ACTUAL" ]; then
        echo "Oracle JDBC checksum mismatch." >&2
        exit 1
    fi
    mv "$TASK_ORACLE/ojdbc11.jar.download" "$TASK_ORACLE/ojdbc11.jar"
fi
"$TASK_JAVA/bin/javac" -d "$TASK_ORACLE/classes" OracleBridge/OracleBridge.java
"$TASK_JAVA/bin/java" -cp "$TASK_ORACLE/classes" OracleBridge --self-test
if [ ! -x "$TASK_ORACLE/jre/bin/java" ]; then
    "$TASK_JAVA/bin/jlink" --add-modules java.base,java.sql,java.naming,java.management,java.security.jgss,java.xml,jdk.crypto.ec,jdk.unsupported --strip-debug --no-man-pages --no-header-files --compress=zip-6 --output "$TASK_ORACLE/jre"
fi
swift build -c release
swift scripts/make-icon.swift "$TASK_ROOT/build/AppIcon.iconset"
iconutil -c icns "$TASK_ROOT/build/AppIcon.iconset" -o "$TASK_ROOT/build/AppIcon.icns"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources/Oracle"
cp "$TASK_ROOT/build/AppIcon.icns" "$TASK_APP/Contents/Resources/"
cp .build/release/dbdbdeep "$TASK_APP/Contents/MacOS/dbdbdeep"
cp "$TASK_ORACLE/ojdbc11.jar" "$TASK_APP/Contents/Resources/Oracle/"
cp -R "$TASK_ORACLE/classes" "$TASK_APP/Contents/Resources/Oracle/"
if [ ! -d "$TASK_APP/Contents/Resources/Oracle/jre" ]; then
    cp -R "$TASK_ORACLE/jre" "$TASK_APP/Contents/Resources/Oracle/"
fi
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
codesign --force --deep --sign - "$TASK_APP"
echo "Built: $TASK_APP"
