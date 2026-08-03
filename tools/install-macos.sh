#!/usr/bin/env bash
#
# Builds the Mac app and installs it into /Applications.
#
# Usage:
#   tools/install-macos.sh                 # Release build, install to /Applications
#   tools/install-macos.sh --debug         # Debug build instead
#   tools/install-macos.sh --dest ~/Applications
#   tools/install-macos.sh --build-only    # build, print the path, don't install
#
# Build products go to build/macos inside the repo rather than the shared
# DerivedData, so this can't be confused by — or confuse — whatever Xcode has
# open.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO_ROOT/OfflineListen.xcodeproj"
SCHEME="OfflineListen"
DERIVED_DATA="$REPO_ROOT/build/macos"
APP_NAME="OfflineListen.app"

CONFIGURATION="Release"
DEST="/Applications"
BUILD_ONLY=0

while [[ $# -gt 0 ]]; do
	case "$1" in
		--debug)      CONFIGURATION="Debug"; shift ;;
		--release)    CONFIGURATION="Release"; shift ;;
		--dest)       DEST="${2:?--dest needs a directory}"; shift 2 ;;
		--build-only) BUILD_ONLY=1; shift ;;
		-h|--help)    sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*)            echo "Unknown option: $1" >&2; exit 2 ;;
	esac
done

if [[ ! -d "$PROJECT" ]]; then
	echo "Can't find $PROJECT — run this from a checkout of the repo." >&2
	exit 1
fi

echo "==> Building $SCHEME ($CONFIGURATION) for macOS"
xcodebuild \
	-project "$PROJECT" \
	-scheme "$SCHEME" \
	-configuration "$CONFIGURATION" \
	-destination 'platform=macOS' \
	-derivedDataPath "$DERIVED_DATA" \
	build \
	| grep -E '^(\*\*|.*error:)' || true

# xcodebuild's exit status is lost to the pipe above, so confirm by looking for
# the product rather than trusting the log.
BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME"
if [[ ! -d "$BUILT_APP" ]]; then
	echo "Build failed — no app at $BUILT_APP" >&2
	exit 1
fi
echo "==> Built $BUILT_APP"

if [[ "$BUILD_ONLY" == "1" ]]; then
	echo "$BUILT_APP"
	exit 0
fi

TARGET="$DEST/$APP_NAME"

# A running copy can't be replaced cleanly; ask it to quit first.
if pgrep -f "$TARGET/Contents/MacOS/OfflineListen" > /dev/null 2>&1; then
	echo "==> Quitting the running copy"
	osascript -e 'quit app "OfflineListen"' 2>/dev/null || true
	sleep 2
fi

echo "==> Installing to $TARGET"
# `ditto` rather than `cp -R`: it preserves the bundle's extended attributes and
# code signature, which a plain copy can strip and thereby break the signature.
if [[ -w "$DEST" ]]; then
	rm -rf "$TARGET"
	ditto "$BUILT_APP" "$TARGET"
else
	echo "    $DEST isn't writable by you — using sudo."
	sudo rm -rf "$TARGET"
	sudo ditto "$BUILT_APP" "$TARGET"
fi

# Worth checking: an install that silently broke the signature launches fine
# today and gets refused after the next reboot.
if codesign --verify --deep --strict "$TARGET" 2>/dev/null; then
	echo "==> Signature verified"
else
	echo "==> Warning: the installed copy doesn't pass signature verification." >&2
fi

echo "==> Installed. Open it with:  open -a \"$TARGET\""
