#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="$SCRIPT_DIR/.work"
ARTIFACT_DIR="$SCRIPT_DIR/artifacts"
REPORT="$ARTIFACT_DIR/phase3-clean-ui-build-report.txt"
EXPECTED_IPA_SHA256="9794c384461a8f5fd761a515ac667ff518e2a7744815964746ae2ce200132c31"
PINNED_MANIFEST_URL="https://service-adhoc.dji.com/ios/plist/0B64345F7EAA4DA9A7A2DFAE555E1462"
OTA_PAGE_URL="https://service-adhoc.dji.com/ios/app/65af52b3-95b5-45b7-947e-1780cef4360b"
USER_AGENT="Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1"
ORIGINAL_IPA="$WORK_DIR/DJI_Mimo_2.6.1_official_ota.ipa"
NO_WATCH_IPA="$WORK_DIR/DJI_Mimo_2.6.1_noWatch.ipa"
FINAL_IPA="$ARTIFACT_DIR/DJI_Mimo_2.6.1_CleanUI.ipa"
FINAL_SHA_FILE="$ARTIFACT_DIR/DJI_Mimo_2.6.1_CleanUI.sha256.txt"
LOAD_PATH='@executable_path/Frameworks/FLEXLoader.dylib'

case "$WORK_DIR" in
    "$SCRIPT_DIR"/.work) ;;
    *) echo "error: unsafe work directory: $WORK_DIR" >&2; exit 1 ;;
esac
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$ARTIFACT_DIR"
rm -f "$FINAL_IPA" "$FINAL_SHA_FILE" "$REPORT"
touch "$REPORT"

log() {
    echo "$*" | tee -a "$REPORT"
}

failure_report() {
    status=$?
    trap - EXIT
    if [[ "$status" -ne 0 ]]; then
        echo "result=FAIL exit_status=$status" >> "$REPORT"
    fi
    exit "$status"
}
trap failure_report EXIT

if [[ "$(uname -s)" != "Darwin" ]]; then
    log "error=macOS runner required"
    exit 1
fi
for tool in curl git python3 plutil xcodebuild xcrun otool lipo unzip zip; do
    command -v "$tool" >/dev/null || { log "error=missing tool $tool"; exit 1; }
done

download_manifest() {
    local url="$1"
    local output="$2"
    curl --fail --silent --show-error --location --retry 3 \
        --user-agent "$USER_AGENT" \
        --output "$output" \
        "$url"
}

download_official_ipa() {
    local url="$1"
    local output="$2"
    local attempt=1
    local max_attempts=6
    local status=0
    local existing_bytes=0

    while (( attempt <= max_attempts )); do
        if [[ -f "$output" ]]; then
            existing_bytes="$(stat -f%z "$output")"
        else
            existing_bytes=0
        fi
        log "official_ipa_download_attempt=$attempt/$max_attempts resume_from_bytes=$existing_bytes"

        if curl --fail --show-error --location --http1.1 \
            --retry 5 --retry-all-errors --retry-delay 5 \
            --connect-timeout 30 \
            --continue-at - \
            --output "$output" \
            "$url"; then
            log "official_ipa_download_complete=true attempts_used=$attempt final_bytes=$(stat -f%z "$output")"
            return 0
        else
            status=$?
        fi

        log "official_ipa_download_attempt_failed=$attempt curl_status=$status partial_bytes=$(stat -f%z "$output" 2>/dev/null || echo 0)"
        if (( attempt == max_attempts )); then
            return "$status"
        fi

        sleep $(( attempt * 5 ))
        (( attempt += 1 ))
    done
}

manifest_is_valid() {
    python3 - "$1" <<'PY'
import plistlib
import sys
from pathlib import Path

try:
    value = plistlib.loads(Path(sys.argv[1]).read_bytes())
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if isinstance(value, dict) and value.get("items") else 1)
PY
}

MANIFEST="$WORK_DIR/manifest.plist"
MANIFEST_URL="$PINNED_MANIFEST_URL"
log "phase=manifest pinned_url=$PINNED_MANIFEST_URL"
download_manifest "$MANIFEST_URL" "$MANIFEST"
if ! manifest_is_valid "$MANIFEST"; then
    log "manifest_pinned_token=expired refreshing_from_official_ota_page=true"
    OTA_PAGE="$WORK_DIR/ota-page.html"
    curl --fail --silent --show-error --location --retry 3 \
        --user-agent "$USER_AGENT" \
        --output "$OTA_PAGE" \
        "$OTA_PAGE_URL"
    MANIFEST_URL="$(python3 - "$OTA_PAGE" <<'PY'
import re
import sys
from pathlib import Path

html = Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(r'var\s+plistUrl\s*=\s*"([^"]+)"', html)
if not match:
    raise SystemExit("official OTA page did not expose plistUrl")
print(match.group(1).replace(r"\/", "/"))
PY
)"
    [[ "$MANIFEST_URL" == https://service-adhoc.dji.com/ios/plist/* ]] || {
        log "error=refreshed manifest is not on service-adhoc.dji.com"
        exit 1
    }
    download_manifest "$MANIFEST_URL" "$MANIFEST"
    manifest_is_valid "$MANIFEST" || { log "error=official manifest is invalid"; exit 1; }
fi
plutil -lint "$MANIFEST"

PACKAGE_METADATA="$WORK_DIR/package-metadata.json"
python3 - "$MANIFEST" "$PACKAGE_METADATA" <<'PY'
import json
import plistlib
import sys
from pathlib import Path
from urllib.parse import urlparse

manifest = plistlib.loads(Path(sys.argv[1]).read_bytes())
item = manifest["items"][0]
metadata = item["metadata"]
assets = item["assets"]
package = next(asset for asset in assets if asset.get("kind") == "software-package")
url = package["url"]
host = (urlparse(url).hostname or "").lower()
if host != "djicdn.com" and not host.endswith(".djicdn.com"):
    raise SystemExit(f"software-package host is not an allowed DJI CDN: {host}")
if metadata.get("bundle-identifier") != "com.dji.djikino.ci":
    raise SystemExit("unexpected bundle identifier")
if metadata.get("bundle-version") != "2.6.1":
    raise SystemExit("unexpected bundle version")
Path(sys.argv[2]).write_text(
    json.dumps(
        {
            "bundle_identifier": metadata.get("bundle-identifier"),
            "bundle_version": metadata.get("bundle-version"),
            "title": metadata.get("title"),
            "package_url": url,
            "package_host": host,
        },
        indent=2,
    ),
    encoding="utf-8",
)
PY

PACKAGE_URL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["package_url"])' "$PACKAGE_METADATA")"
PACKAGE_HOST="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["package_host"])' "$PACKAGE_METADATA")"
log "manifest_url=$MANIFEST_URL"
log "package_domain=$PACKAGE_HOST version=2.6.1 bundle_id=com.dji.djikino.ci"
log "phase=download official_ipa=true"
download_official_ipa "$PACKAGE_URL" "$ORIGINAL_IPA"

ORIGINAL_SHA="$(shasum -a 256 "$ORIGINAL_IPA" | awk '{print $1}')"
log "official_ipa_size=$(stat -f%z "$ORIGINAL_IPA") official_ipa_sha256=$ORIGINAL_SHA"
[[ "$ORIGINAL_SHA" == "$EXPECTED_IPA_SHA256" ]] || {
    log "error=official IPA SHA-256 mismatch; injection blocked"
    exit 1
}
/usr/bin/unzip -tq "$ORIGINAL_IPA" >/dev/null

ORIGINAL_TREE="$WORK_DIR/original-tree"
/usr/bin/unzip -q "$ORIGINAL_IPA" -d "$ORIGINAL_TREE"
shopt -s nullglob
original_apps=("$ORIGINAL_TREE"/Payload/*.app)
shopt -u nullglob
[[ "${#original_apps[@]}" -eq 1 ]] || { log "error=expected one Payload app"; exit 1; }
ORIGINAL_APP="${original_apps[0]}"
EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$ORIGINAL_APP/Info.plist")"
MAIN_EXECUTABLE="$ORIGINAL_APP/$EXECUTABLE_NAME"
[[ -f "$MAIN_EXECUTABLE" ]] || { log "error=main executable missing"; exit 1; }
[[ -d "$ORIGINAL_APP/Watch" ]] || { log "error=expected Watch directory is missing"; exit 1; }
[[ -d "$ORIGINAL_APP/PlugIns/DJIBackgroundDownloadExtension.appex" ]] || {
    log "error=DJIBackgroundDownloadExtension.appex missing before modification"
    exit 1
}

cryptids="$(otool -l "$MAIN_EXECUTABLE" | awk '$1 == "cryptid" { print $2 }')"
[[ -n "$cryptids" ]] || { log "error=main executable has no encryption load command"; exit 1; }
while IFS= read -r cryptid; do
    [[ "$cryptid" == "0" ]] || { log "error=main executable cryptid is $cryptid"; exit 1; }
done <<< "$cryptids"
[[ "$(lipo -archs "$MAIN_EXECUTABLE")" == *arm64* ]] || { log "error=main executable lacks arm64"; exit 1; }
log "main_executable=$EXECUTABLE_NAME architectures=$(lipo -archs "$MAIN_EXECUTABLE") cryptid=0"

SNAPSHOT="$WORK_DIR/original-app-inventory.json"
python3 "$SCRIPT_DIR/verify_phase2_changes.py" snapshot "$ORIGINAL_APP" "$SNAPSHOT"

NO_WATCH_TREE="$WORK_DIR/no-watch-tree"
/usr/bin/ditto "$ORIGINAL_TREE" "$NO_WATCH_TREE"
shopt -s nullglob
no_watch_apps=("$NO_WATCH_TREE"/Payload/*.app)
shopt -u nullglob
[[ "${#no_watch_apps[@]}" -eq 1 ]] || { log "error=no-Watch tree app count invalid"; exit 1; }
NO_WATCH_APP="${no_watch_apps[0]}"
rm -rf "$NO_WATCH_APP/Watch"
[[ ! -d "$NO_WATCH_APP/Watch" ]] || { log "error=Watch removal failed"; exit 1; }
[[ -d "$NO_WATCH_APP/PlugIns/DJIBackgroundDownloadExtension.appex" ]] || {
    log "error=background extension was removed"
    exit 1
}
/usr/libexec/PlistBuddy -c 'Delete :UISupportedInterfaceOrientations' \
    "$NO_WATCH_APP/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :UISupportedInterfaceOrientations array' \
    "$NO_WATCH_APP/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :UISupportedInterfaceOrientations:0 string UIInterfaceOrientationPortrait' \
    "$NO_WATCH_APP/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :UISupportedInterfaceOrientations:1 string UIInterfaceOrientationLandscapeLeft' \
    "$NO_WATCH_APP/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :UISupportedInterfaceOrientations:2 string UIInterfaceOrientationLandscapeRight' \
    "$NO_WATCH_APP/Info.plist"
plutil -lint "$NO_WATCH_APP/Info.plist"
log "phase=orientation_capability iphone_orientations=portrait,landscapeLeft,landscapeRight"
(
    cd "$NO_WATCH_TREE"
    /usr/bin/zip -qry -y "$NO_WATCH_IPA" Payload
)
/usr/bin/unzip -tq "$NO_WATCH_IPA" >/dev/null
NO_WATCH_SHA="$(shasum -a 256 "$NO_WATCH_IPA" | awk '{print $1}')"
log "phase=no_watch no_watch_sha256=$NO_WATCH_SHA"

export MIMO_CLEAN_WORK_DIR="$WORK_DIR"
log "phase=flex_build flex_commit=63a6f588841e94e4c3adaa045ff16eb8163f0bb4"
bash "$SCRIPT_DIR/build-flex-macos.sh"
log "phase=inject insert_dylib_commit=eb7278162af8fcc372e7f2946a2dee6a386b17d8"
bash "$SCRIPT_DIR/inject-flex-macos.sh" "$NO_WATCH_IPA" "$FINAL_IPA"

FINAL_TREE="$WORK_DIR/final-tree"
/usr/bin/unzip -q "$FINAL_IPA" -d "$FINAL_TREE"
shopt -s nullglob
final_apps=("$FINAL_TREE"/Payload/*.app)
shopt -u nullglob
[[ "${#final_apps[@]}" -eq 1 ]] || { log "error=final Payload app count invalid"; exit 1; }
FINAL_APP="${final_apps[0]}"
FINAL_MAIN="$FINAL_APP/$EXECUTABLE_NAME"

[[ ! -d "$FINAL_APP/Watch" ]] || { log "error=Watch directory present in final IPA"; exit 1; }
final_orientations="$(/usr/libexec/PlistBuddy -c 'Print :UISupportedInterfaceOrientations' \
    "$FINAL_APP/Info.plist")"
for orientation in UIInterfaceOrientationPortrait \
                   UIInterfaceOrientationLandscapeLeft \
                   UIInterfaceOrientationLandscapeRight; do
    grep -F "$orientation" <<< "$final_orientations" >/dev/null || {
        log "error=final Info.plist missing orientation $orientation"
        exit 1
    }
done
[[ -d "$FINAL_APP/PlugIns/DJIBackgroundDownloadExtension.appex" ]] || {
    log "error=background extension missing in final IPA"
    exit 1
}
[[ -d "$FINAL_APP/Frameworks/FLEX.framework" ]] || { log "error=FLEX.framework missing"; exit 1; }
[[ -f "$FINAL_APP/Frameworks/FLEXLoader.dylib" ]] || { log "error=FLEXLoader.dylib missing"; exit 1; }
[[ "$(otool -l "$FINAL_MAIN" | grep -F -c "name $LOAD_PATH ")" -eq 1 ]] || {
    log "error=final LC_LOAD_DYLIB verification failed"
    exit 1
}
final_cryptids="$(otool -l "$FINAL_MAIN" | awk '$1 == "cryptid" { print $2 }')"
[[ -n "$final_cryptids" ]] || { log "error=final executable has no encryption command"; exit 1; }
while IFS= read -r cryptid; do
    [[ "$cryptid" == "0" ]] || { log "error=final cryptid is $cryptid"; exit 1; }
done <<< "$final_cryptids"
[[ "$(lipo -archs "$FINAL_MAIN")" == *arm64* ]] || { log "error=final executable lacks arm64"; exit 1; }

python3 "$SCRIPT_DIR/verify_phase2_changes.py" verify "$SNAPSHOT" "$FINAL_APP" "$EXECUTABLE_NAME" | tee -a "$REPORT"
/usr/bin/unzip -tq "$FINAL_IPA" >/dev/null
FINAL_SHA="$(shasum -a 256 "$FINAL_IPA" | awk '{print $1}')"
printf '%s  %s\n' "$FINAL_SHA" "DJI_Mimo_2.6.1_CleanUI.ipa" > "$FINAL_SHA_FILE"

log "zip_test=PASS"
log "watch_directory=absent"
log "iphone_landscape_capability=present"
log "background_extension=present"
log "flex_framework=present"
log "flex_loader=present"
log "lc_load_dylib=$LOAD_PATH count=1"
log "final_architectures=$(lipo -archs "$FINAL_MAIN") final_cryptid=0"
log "final_ipa_size=$(stat -f%z "$FINAL_IPA") final_ipa_sha256=$FINAL_SHA"
log "result=PASS unsigned_for_resigning=true"

echo "===== FINAL MAIN EXECUTABLE LOAD COMMAND ====="
otool -l "$FINAL_MAIN" | grep -A 5 -B 1 -F "name $LOAD_PATH "
echo "===== FINAL MAIN EXECUTABLE DEPENDENCIES ====="
otool -L "$FINAL_MAIN"
trap - EXIT
