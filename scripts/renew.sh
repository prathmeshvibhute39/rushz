#!/bin/bash
# Keeps Rushz installed on your iPhone. A free Apple ID signs apps for 7 days only, so this re-signs and
# reinstalls it before that runs out. launchd runs it every 6 hours; it only does real work when the signing
# profile has less than RENEW_WITHIN_DAYS left (or with --force). The phone must be reachable: on the cable,
# or on the same Wi-Fi with "Connect via network" ticked in Xcode > Window > Devices and Simulators.
# Your songs, playlists and sign-in survive a reinstall (same app id).
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../App" && pwd)"
# Your iPhone's identifier: `xcrun devicectl list devices` (the Identifier column).
UDID="${RUSHZ_DEVICE_UDID:?set RUSHZ_DEVICE_UDID to your iPhone identifier}"
BUNDLE="${RUSHZ_BUNDLE_ID:-com.example.rushz}"  # must match PRODUCT_BUNDLE_IDENTIFIER in project.yml
RENEW_WITHIN_DAYS=2
BUILD_DIR="$HOME/Library/Caches/rushz-build"
LOG="$HOME/Library/Logs/Rushz/renew.log"
PROFILE_DIRS=("$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles")
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"

mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
echo "=== $(date '+%F %T') ${1:-} ==="

notify() { osascript -e "display notification \"$1\" with title \"Rushz\"" >/dev/null 2>&1 || true; }

# Prints "<expiry epoch> <path>" for every signing profile of this app.
profiles() {
    python3 - "$BUNDLE" "${PROFILE_DIRS[@]}" <<'PY'
import glob, os, plistlib, subprocess, sys
bundle, dirs = sys.argv[1], sys.argv[2:]
for d in dirs:
    for f in glob.glob(os.path.join(d, "*.mobileprovision")):
        raw = subprocess.run(["security", "cms", "-D", "-i", f], capture_output=True).stdout
        try:
            p = plistlib.loads(raw)
        except Exception:
            continue
        if p.get("Entitlements", {}).get("application-identifier", "").endswith("." + bundle):
            print(int(p["ExpirationDate"].timestamp()), f)
PY
}

latest_expiry() { profiles | sort -n | tail -1 | cut -d' ' -f1; }

now=$(date +%s)
expiry=$(latest_expiry); expiry=${expiry:-0}
echo "signing profile expires: $( [ "$expiry" -gt 0 ] && date -r "$expiry" '+%F %T' || echo none )"

if [ "${1:-}" != "--force" ] && [ "$expiry" -gt $((now + RENEW_WITHIN_DAYS * 86400)) ]; then
    echo "more than $RENEW_WITHIN_DAYS days left, nothing to do"
    exit 0
fi

if ! xcrun devicectl list devices 2>/dev/null | grep "$UDID" | grep -qv -i "unavailable"; then
    echo "iPhone not reachable, will retry on the next run"
    if [ "$expiry" -lt $((now + 86400)) ]; then
        notify "Signing runs out within a day and your iPhone isn't reachable. Put it on the Mac's Wi-Fi or plug it in."
    fi
    exit 0
fi

# A fresh 7-day profile: set the current one aside so Xcode has to create a new one (restored if anything fails).
backup=$(mktemp -d)
profiles | while read -r _ f; do mv "$f" "$backup/"; done
restore() { for f in "$backup"/*.mobileprovision; do [ -e "$f" ] && mv "$f" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"; done; }

if command -v xcodegen >/dev/null && [ "$PROJECT_DIR/project.yml" -nt "$PROJECT_DIR/Rushz.xcodeproj/project.pbxproj" ]; then
    (cd "$PROJECT_DIR" && xcodegen generate --quiet)
fi

if ! xcodebuild -project "$PROJECT_DIR/Rushz.xcodeproj" -scheme Rushz -configuration Release \
        -destination "id=$UDID" -derivedDataPath "$BUILD_DIR" -allowProvisioningUpdates -quiet build; then
    echo "build failed"
    [ -z "$(latest_expiry)" ] && restore
    notify "Couldn't rebuild Rushz. Open Xcode and check Settings > Accounts is still signed in."
    exit 1
fi

if ! xcrun devicectl device install app --device "$UDID" "$BUILD_DIR/Build/Products/Release-iphoneos/Rushz.app"; then
    echo "install failed"
    notify "Couldn't reinstall Rushz on your iPhone. Unlock it and keep it on Wi-Fi; I'll retry."
    exit 1
fi

rm -rf "$backup"
new=$(latest_expiry)
echo "renewed: signing now expires $(date -r "$new" '+%F %T')"
notify "Rushz renewed. It's good until $(date -r "$new" '+%a %d %b')."
