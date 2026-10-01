#!/bin/bash
# mutewake installer.
#
# Builds mutewake.app from source into $APP_DIR (default ~/Applications),
# generates the launchd agent for THIS machine, and starts it. The agent plist
# cannot be shipped as a static file: launchd does not expand "~", so the
# absolute path has to be written at install time.
set -euo pipefail

LABEL="io.github.00mkp.mutewake"
LIBDIR="$HOME/.local/share/mutewake"
BINDIR="$HOME/.local/bin"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$LIBDIR/manifest"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "mutewake is macOS-only (this is $(uname -s))."

# Where the previous install put the app: the manifest's record, or the pre-0.4
# location under ~/.local/share. Removed once the new copy is in place, so
# moving APP_DIR (or upgrading) never leaves a second copy behind.
PREV_APP="$LIBDIR/mutewake.app"
recorded=""
if [[ -f "$MANIFEST" ]]; then
  recorded="$(awk -F= '$1=="app"{sub(/^[^=]*=/,""); print; exit}' "$MANIFEST")"
  [[ -n "$recorded" ]] && PREV_APP="$recorded"
fi

# APP_DIR defaults to wherever the last install went, so a plain `mutewake
# update` never silently moves an app installed with APP_DIR=/Applications.
if [[ -z "${APP_DIR:-}" ]]; then
  if [[ -n "$recorded" ]]; then APP_DIR="$(dirname "$recorded")"; else APP_DIR="$HOME/Applications"; fi
fi
case "$APP_DIR" in /*) ;; *) APP_DIR="$PWD/$APP_DIR" ;; esac   # relative to where you ran it
# Checked now, before anything is stopped: failing later would leave the agent
# down. Then canonicalized, so "~/Applications/" and "~/Applications" (or a
# symlinked path) are recognised as the same place below.
mkdir -p "$APP_DIR" 2>/dev/null || die "cannot create $APP_DIR"
[[ -w "$APP_DIR" ]] || die "$APP_DIR is not writable. Pick another APP_DIR (the default ~/Applications needs no admin rights)."
APP_DIR="$(cd "$APP_DIR" && pwd -P)"
APP="$APP_DIR/mutewake.app"

[[ -f "$SRC/VERSION" ]] || die "$SRC/VERSION is missing; this is not a complete source tree."
VERSION="$(tr -d '[:space:]' < "$SRC/VERSION")"
[[ -n "$VERSION" ]] || die "$SRC/VERSION is empty."

if ! command -v swiftc >/dev/null 2>&1; then
  die "swiftc not found. Install the Xcode Command Line Tools:
    xcode-select --install"
fi

# Built in a staging directory and moved into place only once it is complete, so
# a failed build leaves the installed copy untouched and still running.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
BUILD="$STAGE/mutewake.app"

echo "==> Building mutewake.app"
mkdir -p "$BUILD/Contents/MacOS" "$BUILD/Contents/Resources" "$BINDIR"
cat > "$BUILD/Contents/Info.plist" <<PLIST_EOF
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
	<key>CFBundleIconFile</key><string>mutewake</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSUIElement</key><true/>
</dict>
</plist>
PLIST_EOF

# Pin the deployment target to match LSMinimumSystemVersion. Left to itself,
# swiftc stamps the toolchain's own default (newer than the running OS), and
# while launchd ignores that, LaunchServices then refuses to open the app from
# Finder or Spotlight.
swiftc -O -target "$(uname -m)-apple-macos13.0" \
  -o "$BUILD/Contents/MacOS/mutewake" "$SRC"/src/*.swift

echo "==> Drawing the app icon"
swiftc -O -o "$STAGE/make-icon" "$SRC/tools/make-icon.swift"
"$STAGE/make-icon" "$STAGE/mutewake.iconset"
iconutil -c icns "$STAGE/mutewake.iconset" -o "$BUILD/Contents/Resources/mutewake.icns"

# Ad-hoc signature: enough for macOS to run it locally, and it never leaves this
# machine, so no Developer ID or notarization is involved.
codesign --force --sign - --identifier "$LABEL" "$BUILD" >/dev/null 2>&1 || true

echo "==> Stopping any running instance"
launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true

echo "==> Installing $APP"
rm -rf "$APP"
mv "$BUILD" "$APP"
# -ef compares the actual directories, not their spellings: a string compare
# would treat ".../Applications//mutewake.app" as different and delete the copy
# that was just moved into place.
if [[ "$PREV_APP" == */mutewake.app && -d "$PREV_APP" && ! "$PREV_APP" -ef "$APP" ]]; then
  if rm -rf "$PREV_APP" 2>/dev/null; then
    echo "    removed the previous copy at $PREV_APP"
  else
    echo "    warning: could not remove the previous copy at $PREV_APP; delete it by hand"
  fi
fi
# Register with LaunchServices now, so Spotlight and Launchpad find it at once.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true

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

# Checked before the manifest is rewritten: a reinstall or `mutewake update` must
# keep the user's on/off choice, and only a first install switches the feature on.
FIRST_INSTALL=0
[[ -f "$MANIFEST" ]] || FIRST_INSTALL=1
mkdir -p "$LIBDIR"

echo "==> Recording the install manifest"
# `mutewake update` needs to know where this tree lives: the installed CLI is a
# copy and would otherwise have no way back to the source.
cat > "$MANIFEST" <<MANIFEST_EOF
version=$VERSION
source=$SRC
app=$APP
installed=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MANIFEST_EOF

echo "==> Starting"
if (( FIRST_INSTALL )); then
  rm -f "$HOME/.config/mutewake/disabled"
fi
launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null || true
sleep 1

if ! launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  die "the agent did not start. See $HOME/Library/Logs/mutewake.err.log"
fi

echo
echo "mutewake $VERSION is installed and running."
if [[ -f "$HOME/.config/mutewake/disabled" ]]; then
  echo "The feature is still off, as you left it. Turn it on with: mutewake on"
fi
case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) echo
     echo "NOTE: $BINDIR is not on your PATH. Add this to your shell profile:"
     echo "    export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac
echo
echo "It lives at $APP — its icon is the sleeping speaker in your menu bar."
echo "Try:  mutewake status"
echo "Off:  mutewake off"
