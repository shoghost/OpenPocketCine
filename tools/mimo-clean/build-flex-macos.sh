#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="${MIMO_CLEAN_WORK_DIR:-$SCRIPT_DIR/.work}"
FLEX_DIR="$WORK_DIR/sources/FLEX"
SOURCE_FILES=(
    "$SCRIPT_DIR/MimoStreamingEntry.m"
    "$SCRIPT_DIR/MimoCleanController.m"
    "$SCRIPT_DIR/MimoKickConfig.m"
    "$SCRIPT_DIR/MimoKickModels.m"
    "$SCRIPT_DIR/MimoKickClient.m"
    "$SCRIPT_DIR/MimoKickHUDView.m"
)
BUILD_DIR="$WORK_DIR/flex-build"
DERIVED_DIR="$BUILD_DIR/DerivedData"
FLEX_REPOSITORY="https://github.com/FLEXTool/FLEX.git"
FLEX_COMMIT="63a6f588841e94e4c3adaa045ff16eb8163f0bb4"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: FLEX must be built on macOS with Xcode." >&2
    exit 1
fi
command -v xcodebuild >/dev/null || { echo "error: xcodebuild not found" >&2; exit 1; }
command -v xcrun >/dev/null || { echo "error: xcrun not found" >&2; exit 1; }
for source_file in "${SOURCE_FILES[@]}"; do
    [[ -f "$source_file" ]] || { echo "error: missing $source_file" >&2; exit 1; }
done

mkdir -p "$WORK_DIR/sources"
if [[ ! -d "$FLEX_DIR/.git" ]]; then
    git init -q "$FLEX_DIR"
    git -C "$FLEX_DIR" remote add origin "$FLEX_REPOSITORY"
fi
git -C "$FLEX_DIR" fetch --depth 1 origin "$FLEX_COMMIT"
git -C "$FLEX_DIR" checkout -q --detach FETCH_HEAD
[[ "$(git -C "$FLEX_DIR" rev-parse HEAD)" == "$FLEX_COMMIT" ]] || {
    echo "error: FLEX checkout does not match pinned commit" >&2
    exit 1
}

case "$BUILD_DIR" in
    "$WORK_DIR"/*) ;;
    *) echo "error: unsafe FLEX build path: $BUILD_DIR" >&2; exit 1 ;;
esac
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

xcodebuild \
    -project "$FLEX_DIR/FLEX.xcodeproj" \
    -scheme FLEX \
    -configuration Release \
    -sdk iphoneos \
    -derivedDataPath "$DERIVED_DIR" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    IPHONEOS_DEPLOYMENT_TARGET=14.0 \
    CODE_SIGNING_ALLOWED=NO \
    BUILD_LIBRARY_FOR_DISTRIBUTION=NO \
    build

FLEX_FRAMEWORK="$(find "$DERIVED_DIR/Build/Products" -type d -name FLEX.framework -path '*Release-iphoneos*' -print -quit)"
[[ -n "$FLEX_FRAMEWORK" ]] || { echo "error: FLEX.framework was not produced" >&2; exit 1; }
/usr/bin/ditto "$FLEX_FRAMEWORK" "$BUILD_DIR/FLEX.framework"

SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos clang \
    -arch arm64 \
    -isysroot "$SDK_PATH" \
    -mios-version-min=14.0 \
    -fobjc-arc \
    -dynamiclib \
    "${SOURCE_FILES[@]}" \
    -F "$BUILD_DIR" \
    -framework FLEX \
    -framework UIKit \
    -framework Foundation \
    -framework CoreGraphics \
    -framework QuartzCore \
    -install_name '@rpath/FLEXLoader.dylib' \
    -Wl,-rpath,@loader_path \
    -o "$BUILD_DIR/FLEXLoader.dylib"

[[ "$(lipo -archs "$BUILD_DIR/FLEX.framework/FLEX")" == *arm64* ]] || {
    echo "error: FLEX.framework is missing arm64" >&2
    exit 1
}
[[ "$(lipo -archs "$BUILD_DIR/FLEXLoader.dylib")" == *arm64* ]] || {
    echo "error: FLEXLoader.dylib is missing arm64" >&2
    exit 1
}
otool -L "$BUILD_DIR/FLEXLoader.dylib" | grep -F '@rpath/FLEX.framework/FLEX' >/dev/null || {
    echo "error: FLEXLoader does not link the built FLEX.framework" >&2
    exit 1
}
otool -L "$BUILD_DIR/FLEXLoader.dylib" | grep -F 'CoreGraphics.framework/CoreGraphics' >/dev/null || {
    echo "error: FLEXLoader does not link CoreGraphics.framework" >&2
    exit 1
}
otool -L "$BUILD_DIR/FLEXLoader.dylib" | grep -F 'QuartzCore.framework/QuartzCore' >/dev/null || {
    echo "error: FLEXLoader does not link QuartzCore.framework" >&2
    exit 1
}

echo "[OK] FLEX source commit: $FLEX_COMMIT"
echo "[OK] FLEX.framework architectures: $(lipo -archs "$BUILD_DIR/FLEX.framework/FLEX")"
echo "[OK] FLEXLoader.dylib architectures: $(lipo -archs "$BUILD_DIR/FLEXLoader.dylib")"
otool -L "$BUILD_DIR/FLEXLoader.dylib"
