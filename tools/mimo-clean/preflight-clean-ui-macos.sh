#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORK_DIR="${MIMO_CLEAN_WORK_DIR:-$SCRIPT_DIR/.work}"
BUILD_DIR="$WORK_DIR/flex-build"
REPORT_DIR="$SCRIPT_DIR/artifacts/preflight"
REPORT="$REPORT_DIR/mimo-clean-preflight-report.txt"
SOURCE_FILES=("$SCRIPT_DIR/FLEXLoader.m" "$SCRIPT_DIR/MimoCleanController.m")

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: the Clean UI binary preflight requires macOS and the iPhoneOS SDK" >&2
    exit 1
fi

mkdir -p "$REPORT_DIR"
: >"$REPORT"
exec > >(tee -a "$REPORT") 2>&1

echo "preflight=DJI Mimo Clean UI"
echo "commit=$(git -C "$REPO_ROOT" rev-parse HEAD)"
echo "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "[1/7] Repository and shell checks"
git -C "$REPO_ROOT" diff --check
for script in "$SCRIPT_DIR"/*.sh; do
    bash -n "$script"
done

echo "[2/7] Source contract checks"
if grep -nE 'removeFromSuperview|makeKeyAndVisible|\.children([^A-Za-z]|$)|viewController\.children' "${SOURCE_FILES[@]}"; then
    echo "error: forbidden or invalid Clean UI source pattern found" >&2
    exit 1
fi
grep -F '[viewController childViewControllers]' "${SOURCE_FILES[@]}" >/dev/null
grep -F 'action:@selector(toggleMimoClean:)' "$SCRIPT_DIR/FLEXLoader.m" >/dev/null
if grep -F 'NSClassFromString(@"FLEXManager")' "$SCRIPT_DIR/FLEXLoader.m" >/dev/null; then
    echo "error: FLEX Explorer activation remains in the production gesture path" >&2
    exit 1
fi

echo "[3/7] Build pinned FLEX and link the real arm64/iPhoneOS loader"
bash "$SCRIPT_DIR/build-flex-macos.sh"

SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "[4/7] Standalone Objective-C compile preflight"
xcrun --sdk iphoneos clang \
    -target arm64-apple-ios14.0 \
    -isysroot "$SDK_PATH" \
    -fobjc-arc \
    -fsyntax-only \
    -Wall -Wextra \
    "${SOURCE_FILES[@]}" \
    -F "$BUILD_DIR" \
    -framework FLEX \
    -framework Foundation \
    -framework UIKit \
    -framework CoreGraphics \
    -framework QuartzCore

LOADER="$BUILD_DIR/FLEXLoader.dylib"
echo "[5/7] Mach-O architecture and linked framework verification"
file "$LOADER" | tee "$REPORT_DIR/FLEXLoader.file.txt"
otool -L "$LOADER" | tee "$REPORT_DIR/FLEXLoader.otool-L.txt"
nm -u "$LOADER" | tee "$REPORT_DIR/FLEXLoader.nm-u.txt"
[[ "$(lipo -archs "$LOADER")" == *arm64* ]]
for dependency in \
    '@rpath/FLEX.framework/FLEX' \
    'Foundation.framework/Foundation' \
    'UIKit.framework/UIKit' \
    'CoreGraphics.framework/CoreGraphics' \
    'QuartzCore.framework/QuartzCore'; do
    grep -F "$dependency" "$REPORT_DIR/FLEXLoader.otool-L.txt" >/dev/null || {
        echo "error: missing linked dependency: $dependency" >&2
        exit 1
    }
done

echo "[6/7] Undefined-symbol policy"
if nm -u "$LOADER" | grep -E '(^|[[:space:]])(CGAffineTransformEqualToTransform|CGRectEqualToRect|CGRectGetHeight|CGRectGetWidth)$'; then
    echo "note: CoreGraphics imports are dynamically resolved by the verified CoreGraphics load command"
fi
if otool -l "$LOADER" | grep -F 'LC_LOAD_WEAK_DYLIB' >/dev/null; then
    echo "note: weak load commands present; see otool output"
fi

echo "[7/7] Preflight complete"
echo "finished_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "result=PASS"
