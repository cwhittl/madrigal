#!/bin/bash
# Regenerates the App Store screenshots from the app's DEBUG-only screenshot
# demo mode (MadrigalChat/Services/ScreenshotDemo.swift): fake chats in an
# in-memory store, no iCloud, no real data.
#
# Headless: builds with xcodebuild, drives simulators with simctl, and never
# opens Simulator.app. The Mac shots launch the macOS build and capture its
# window by id, which needs Screen Recording permission for your terminal.
#
# Output sizes match App Store Connect's slots exactly:
#   iphone-6.3  1206x2622  (iPhone 17 Pro; the 6.1"/6.3" slot)
#   iphone-6.9  1320x2868  (iPhone 17 Pro Max)
#   ipad-13     2064x2752
#   mac         2560x1600  (1280x800 pt window at 2x; fits small displays)
# Every PNG is flattened to opaque RGB, since ASC can reject alpha.
#
# Usage: AppStore/capture-screenshots.sh [ios|mac|all]   (default: all)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/AppStore/screenshots"
DD="${DERIVED_DATA:-/tmp/madrigal-dd}"
BUNDLE_ID="dev.whittle.madrigalchat"
IPHONE="${IPHONE_SIM:-iPhone 17 Pro Max}"
IPHONE63="${IPHONE63_SIM:-iPhone 17 Pro}"
IPAD="${IPAD_SIM:-iPad Pro 13-inch (M5)}"
WHAT="${1:-all}"

# Screen name, file name, appearance. One shot per device in dark mode.
SHOTS=(
  "chat     1-chat      light"
  "sidebar  2-sidebar   light"
  "project  3-project   light"
  "search   4-on-device dark"
  "settings 5-settings  light"
)

sim_udid() {
  xcrun simctl list devices available | grep -F "    $1 (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/'
}

capture_ios() {
  echo "==> Building for iOS Simulator"
  xcodebuild build -project "$ROOT/MadrigalChat.xcodeproj" -scheme MadrigalChat \
    -configuration Debug -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$DD" -quiet
  local app="$DD/Build/Products/Debug-iphonesimulator/Madrigal.app"

  for device in "$IPHONE63|iphone-6.3" "$IPHONE|iphone-6.9" "$IPAD|ipad-13"; do
    local name="${device%%|*}" folder="${device##*|}"
    local udid; udid="$(sim_udid "$name")"
    [ -n "$udid" ] || { echo "No simulator named '$name'"; exit 1; }
    echo "==> $name ($udid)"
    xcrun simctl boot "$udid" 2>/dev/null || true
    xcrun simctl bootstatus "$udid" -b >/dev/null
    xcrun simctl install "$udid" "$app"
    xcrun simctl status_bar "$udid" override --time "9:41" --dataNetwork wifi \
      --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 \
      --batteryState discharging --batteryLevel 100
    mkdir -p "$OUT/$folder"

    # The first launch after an install is slow; get it out of the way.
    xcrun simctl launch "$udid" "$BUNDLE_ID" -ScreenshotDemo YES >/dev/null
    sleep 8

    for shot in "${SHOTS[@]}"; do
      read -r screen file appearance <<<"$shot"
      xcrun simctl ui "$udid" appearance "$appearance"
      xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
      xcrun simctl launch "$udid" "$BUNDLE_ID" -ScreenshotDemo YES -DemoScreen "$screen" >/dev/null
      sleep 6
      xcrun simctl io "$udid" screenshot --type=png "$OUT/$folder/$file.png" >/dev/null 2>&1
      # A blank screen compresses to under ~150 KB; relaunch and retake.
      for _ in 1 2; do
        [ "$(stat -f %z "$OUT/$folder/$file.png")" -gt 150000 ] && break
        xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
        xcrun simctl launch "$udid" "$BUNDLE_ID" -ScreenshotDemo YES -DemoScreen "$screen" >/dev/null
        sleep 8
        xcrun simctl io "$udid" screenshot --type=png "$OUT/$folder/$file.png" >/dev/null 2>&1
      done
      echo "    $folder/$file.png"
    done

    xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl ui "$udid" appearance light
    xcrun simctl status_bar "$udid" clear
  done
}

capture_mac() {
  echo "==> Building for macOS"
  xcodebuild build -project "$ROOT/MadrigalChat.xcodeproj" -scheme MadrigalChat \
    -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath "$DD" -quiet
  local app="$DD/Build/Products/Debug/Madrigal.app"
  local log; log="$(mktemp)"
  mkdir -p "$OUT/mac"

  for shot in "${SHOTS[@]}"; do
    read -r screen file appearance <<<"$shot"
    pkill -x Madrigal 2>/dev/null || true
    sleep 1
    : >"$log"
    open -n --stdout "$log" --stderr /dev/null "$app" \
      --args -ScreenshotDemo YES -DemoScreen "$screen" -DemoAppearance "$appearance"
    local id=""
    for _ in $(seq 1 40); do
      id="$(grep -o 'DEMO_WINDOW id=[0-9]*' "$log" | tail -1 | sed 's/.*id=//')" || true
      [ -n "$id" ] && break
      sleep 0.5
    done
    [ -n "$id" ] || { echo "Window never appeared; see $log"; pkill -x Madrigal; exit 1; }
    sleep 6
    # Capture just this window (-o: no shadow), so system alerts or other
    # windows on top never end up in the shot.
    screencapture -x -o -l "$id" "$OUT/mac/$file.png"
    # A sheet can hang a few points below the window; keep the window's area.
    sips -c 1600 2560 --cropOffset 0 0 "$OUT/mac/$file.png" >/dev/null
    echo "    mac/$file.png"
  done
  pkill -x Madrigal 2>/dev/null || true
  rm -f "$log"
}

case "$WHAT" in
  ios) capture_ios ;;
  mac) capture_mac ;;
  all) capture_ios; capture_mac ;;
  *) echo "Usage: $0 [ios|mac|all]"; exit 2 ;;
esac

# Allowed pixel sizes per folder (portrait for iOS, landscape for Mac).
allowed_sizes() {
  case "$1" in
    iphone-6.3) echo "1206x2622 1179x2556" ;;
    iphone-6.9) echo "1320x2868 1290x2796 1260x2736" ;;
    ipad-13)    echo "2064x2752 2048x2732" ;;
    mac)        echo "2880x1800 2560x1600 1440x900 1280x800" ;;
  esac
}

finalize() {
  echo "==> Flattening and checking sizes"
  local bad=0 tmp; tmp="$(mktemp -d)"
  for f in "$OUT"/*/*.png; do
    local folder; folder="$(basename "$(dirname "$f")")"
    local w h
    read -r w h < <(sips -g pixelWidth -g pixelHeight "$f" | awk '/pixel/ {printf "%s ", $2} END {print ""}')
    # PNG -> max-quality JPEG -> PNG drops the alpha channel.
    sips -s format jpeg -s formatOptions 100 "$f" --out "$tmp/x.jpg" >/dev/null
    sips -s format png "$tmp/x.jpg" --out "$f" >/dev/null
    local alpha; alpha="$(sips -g hasAlpha "$f" | awk '/hasAlpha/ {print $2}')"
    local ok=no
    for s in $(allowed_sizes "$folder"); do [ "${w}x${h}" = "$s" ] && ok=yes; done
    printf '%-32s %sx%s alpha=%s %s\n' "${f#"$OUT"/}" "$w" "$h" "$alpha" \
      "$([ "$ok" = yes ] && echo ok || echo 'WRONG SIZE')"
    [ "$ok" = yes ] && [ "$alpha" = no ] || bad=1
  done
  rm -rf "$tmp"
  [ "$bad" = 0 ] || { echo "Some screenshots won't pass App Store Connect"; exit 1; }
}

finalize
