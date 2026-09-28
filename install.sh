#!/bin/bash
# mutewake installer.
#
# Builds the daemon from source, generates the launchd agent for THIS machine,
# and starts it. The agent plist cannot be shipped as a static file: launchd does
# not expand "~", so the absolute path has to be written at install time.
set -euo pipefail

LABEL="io.github.00mkp.mutewake"
LIBDIR="$HOME/.local/share/mutewake"
APP="$LIBDIR/mutewake.app"
BINDIR="$HOME/.local/bin"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$LIBDIR/manifest"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "mutewake is macOS-only (this is $(uname -s))."

[[ -f "$SRC/VERSION" ]] || die "$SRC/VERSION is missing; this is not a complete source tree."
VERSION="$(tr -d '[:space:]' < "$SRC/VERSION")"
[[ -n "$VERSION" ]] || die "$SRC/VERSION is empty."

if ! command -v swiftc >/dev/null 2>&1; then
  die "swiftc not found. Install the Xcode Command Line Tools:
    xcode-select --install"
fi

echo "==> Stopping any running instance"
launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true

echo "==> Building the daemon"
mkdir -p "$APP/Contents/MacOS" "$BINDIR"
cat > "$APP/Contents/Info.plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>mutewake</string>
	<key>CFBundleDisplayName</key><string>mutewake</string>
	<key>CFBundleIdentifier</key><string>$LABEL</string>
	<key>CFBundleExecutable</key><string>mutewake</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSUIElement</key><true/>
</dict>
</plist>
PLIST_EOF

swiftc -O -o "$APP/Contents/MacOS/mutewake" "$SRC"/src/*.swift
# Ad-hoc signature: enough for macOS to run it locally, and it never leaves this
# machine, so no Developer ID or notarization is involved.
codesign --force --sign - --identifier "$LABEL" "$APP" >/dev/null 2>&1 || true

echo "==> Installing the mutewake command"
install -m 755 "$SRC/bin/mutewake" "$BINDIR/mutewake"

echo "==> Generating the launchd agent"
mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$APP/Contents/MacOS/mutewake</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardErrorPath</key>
	<string>$HOME/Library/Logs/mutewake.err.log</string>
</dict>
</plist>
PLIST_EOF
plutil -lint "$PLIST" >/dev/null || die "generated plist is malformed"

echo "==> Recording the install manifest"
# `mutewake update` needs to know where this tree lives: the installed CLI is a
# copy and would otherwise have no way back to the source.
cat > "$MANIFEST" <<MANIFEST_EOF
version=$VERSION
source=$SRC
installed=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MANIFEST_EOF

echo "==> Starting"
rm -f "$HOME/.config/mutewake/disabled"
launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null || true
sleep 1

if ! launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  die "the agent did not start. See $HOME/Library/Logs/mutewake.err.log"
fi

echo
echo "mutewake $VERSION is installed and running."
case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) echo
     echo "NOTE: $BINDIR is not on your PATH. Add this to your shell profile:"
     echo "    export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac
echo
echo "Try:  mutewake status"
echo "Off:  mutewake off"
