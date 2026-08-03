#!/usr/bin/env bash
#
# Build phase: embeds the standalone yt-dlp in the Mac app's Contents/Helpers.
#
# The app bundles a copy so a fresh install can download from every site yt-dlp
# supports without the user setting anything up first. It's a floor, not a
# ceiling — `MacYtDlp` prefers a newer copy if it finds one (a self-updating copy
# in Application Support, or Homebrew's), because yt-dlp chases a moving target
# and the bundled one only moves when the app is rebuilt.
#
# The single-file build is the right one here. Its PyInstaller loader opens a
# POSIX named semaphore at startup, which App Sandbox refuses unless the name
# carries an app-group prefix — but this target isn't sandboxed, so that never
# comes up, and it costs ~36 MB against ~125 MB for the directory build.
#
# No-ops on every platform but macOS, so the iOS build is untouched.

set -euo pipefail

if [ "${PLATFORM_NAME:-}" != "macosx" ]; then
	echo "note: not a macOS build (${PLATFORM_NAME:-unknown}) — skipping the yt-dlp helper."
	exit 0
fi

RELEASE_URL="https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"
# Cached outside DerivedData so a clean build — or Xcode throwing its build
# directory away — doesn't mean re-downloading 36 MB. `build/` is gitignored.
CACHE_DIR="${SRCROOT}/build/tools-cache"
CACHED="${CACHE_DIR}/yt-dlp_macos"

mkdir -p "${CACHE_DIR}"
if [ ! -s "${CACHED}" ]; then
	echo "note: downloading yt-dlp (this happens once; delete ${CACHED} to refresh)…"
	if ! curl -fL --retry 3 --retry-delay 2 -o "${CACHED}.partial" "${RELEASE_URL}"; then
		rm -f "${CACHED}.partial"
		echo "error: couldn't download yt-dlp from ${RELEASE_URL}. Check the network, or place the binary at ${CACHED} by hand." >&2
		exit 1
	fi
	mv "${CACHED}.partial" "${CACHED}"
fi

HELPERS="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
DESTINATION="${HELPERS}/yt-dlp"
mkdir -p "${HELPERS}"
# Copy fresh every time: the previous build's copy carries the previous build's
# signature, and re-signing in place is less predictable than starting clean.
rm -rf "${DESTINATION}"
cp -f "${CACHED}" "${DESTINATION}"
chmod 755 "${DESTINATION}"

# Re-sign with the app's identity so the bundle's own signature stays valid —
# Xcode seals everything under Contents/, and nested code it can't verify fails
# the outer signing step with "code object is not signed at all".
#
# Deliberately no `--options runtime`: the standalone yt-dlp unpacks and dlopens
# its own shared libraries at startup, which the hardened runtime's library
# validation refuses. It's a separate process, so this doesn't weaken the app's
# own hardened runtime.
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [ -z "${IDENTITY}" ]; then
	IDENTITY="-"
fi
codesign --force --sign "${IDENTITY}" --timestamp=none "${DESTINATION}"

echo "note: embedded yt-dlp at ${DESTINATION} (signed with ${IDENTITY})."
