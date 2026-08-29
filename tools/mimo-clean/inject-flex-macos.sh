#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="${MIMO_CLEAN_WORK_DIR:-$SCRIPT_DIR/.work}"
SOURCE_IPA="${1:?usage: inject-flex-macos.sh no-watch-source.ipa output.ipa}"
OUTPUT_IPA="${2:?usage: inject-flex-macos.sh no-watch-source.ipa output.ipa}"
BUILD_DIR="$WORK_DIR/flex-build"
INSERT_SOURCE="$WORK_DIR/sources/insert_dylib"
TOOLS_DIR="$WORK_DIR/tools"
INSERT_REPOSITORY="https://github.com/tyilo/insert_dylib.git"
INSERT_COMMIT="eb7278162af8fcc372e7f2946a2dee6a386b17d8"
LOAD_PATH='@executable_path/Frameworks/FLEXLoader.dylib'

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: injection requires macOS tooling." >&2
    exit 1
fi
[[ -f "$SOURCE_IPA" ]] || { echo "error: source IPA missing: $SOURCE_IPA" >&2; exit 1; }
[[ -d "$BUILD_DIR/FLEX.framework" ]] || { echo "error: FLEX.framework has not been built" >&2; exit 1; }
[[ -f "$BUILD_DIR/FLEXLoader.dylib" ]] || { echo "error: FLEXLoader.dylib has not been built" >&2; exit 1; }

mkdir -p "$WORK_DIR/sources" "$TOOLS_DIR"
if [[ ! -d "$INSERT_SOURCE/.git" ]]; then
    git init -q "$INSERT_SOURCE"
    git -C "$INSERT_SOURCE" remote add origin "$INSERT_REPOSITORY"
fi
git -C "$INSERT_SOURCE" fetch --depth 1 origin "$INSERT_COMMIT"
git -C "$INSERT_SOURCE" checkout -q --detach FETCH_HEAD
[[ "$(git -C "$INSERT_SOURCE" rev-parse HEAD)" == "$INSERT_COMMIT" ]] || {
    echo "error: insert_dylib checkout does not match pinned commit" >&2
    exit 1
}

xcodebuild \
    -project "$INSERT_SOURCE/insert_dylib.xcodeproj" \
    -target insert_dylib \
    -configuration Release \
    CONFIGURATION_BUILD_DIR="$TOOLS_DIR" \
    build
INSERT_DYLIB="$TOOLS_DIR/insert_dylib"
[[ -x "$INSERT_DYLIB" ]] || { echo "error: insert_dylib build failed" >&2; exit 1; }

TEMP_DIR="$(mktemp -d "$WORK_DIR/inject.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
/usr/bin/unzip -q "$SOURCE_IPA" -d "$TEMP_DIR"

shopt -s nullglob
apps=("$TEMP_DIR"/Payload/*.app)
shopt -u nullglob
[[ "${#apps[@]}" -eq 1 ]] || { echo "error: expected exactly one Payload/*.app" >&2; exit 1; }
APP_DIR="${apps[0]}"
[[ ! -d "$APP_DIR/Watch" ]] || { echo "error: no-Watch source unexpectedly contains Watch/" >&2; exit 1; }
[[ -d "$APP_DIR/PlugIns/DJIBackgroundDownloadExtension.appex" ]] || {
    echo "error: required DJIBackgroundDownloadExtension.appex is missing" >&2
    exit 1
}

EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_DIR/Info.plist")"
MAIN_EXECUTABLE="$APP_DIR/$EXECUTABLE_NAME"
[[ -f "$MAIN_EXECUTABLE" ]] || { echo "error: main executable missing" >&2; exit 1; }
if otool -L "$MAIN_EXECUTABLE" | grep -Fq "$LOAD_PATH"; then
    echo "error: FLEXLoader is already injected" >&2
    exit 1
fi

mkdir -p "$APP_DIR/Frameworks"
/usr/bin/ditto "$BUILD_DIR/FLEX.framework" "$APP_DIR/Frameworks/FLEX.framework"
/bin/cp -p "$BUILD_DIR/FLEXLoader.dylib" "$APP_DIR/Frameworks/FLEXLoader.dylib"

"$INSERT_DYLIB" \
    --inplace \
    --strip-codesig \
    --all-yes \
    "$LOAD_PATH" \
    "$MAIN_EXECUTABLE"

load_count="$(otool -l "$MAIN_EXECUTABLE" | grep -F -c "name $LOAD_PATH ")"
[[ "$load_count" -eq 1 ]] || {
    echo "error: expected one FLEXLoader LC_LOAD_DYLIB, found $load_count" >&2
    exit 1
}

mkdir -p "$(dirname "$OUTPUT_IPA")"
rm -f "$OUTPUT_IPA"
(
    cd "$TEMP_DIR"
    /usr/bin/zip -qry -y "$OUTPUT_IPA" Payload
)
/usr/bin/unzip -tq "$OUTPUT_IPA" >/dev/null

echo "[OK] insert_dylib source commit: $INSERT_COMMIT"
echo "[OK] Added one LC_LOAD_DYLIB: $LOAD_PATH"
echo "[OK] Preserved PlugIns/DJIBackgroundDownloadExtension.appex"
echo "[OK] Output: $OUTPUT_IPA"
