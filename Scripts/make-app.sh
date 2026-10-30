#!/usr/bin/env bash
#
# Builds ShellyLanMan.app: compiles the Swift menu-bar app in release mode and
# assembles a .app bundle with the ShellyLanMan server binary in
# Contents/Helpers.
#
# Prerequisite: run Scripts/build-server.sh first so ./Vendored exists.
#
# Env overrides:
#   CODESIGN_IDENTITY   Developer ID (or stable self-signed) identity for
#                       signing. Defaults to ad-hoc ("-") for local use. Use a
#                       stable self-signed identity ("nicx Selfsign") so macOS
#                       keeps login-item, notification and local-network grants
#                       across rebuilds.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDORED="$ROOT/Vendored"
APP="$ROOT/dist/ShellyLanMan.app"
IDENTITY="${CODESIGN_IDENTITY:--}"

# Läuft die App aus genau diesem dist/, würde der Build ihr das Bundle unter den Füßen
# weglöschen: der Prozess liefe mit ALTEM Code aus einem gelöschten Bundle weiter, macOS
# graut ihn aus, das Menü reagiert nicht mehr — beenden ginge nur noch per `kill`. Bei
# dieser App stoppt ein sauberer Quit zusätzlich den ShellyLanMan-Kindprozess.
RUNNING="$(pgrep -f "$APP/Contents/" || true)"
if [[ -n "$RUNNING" ]]; then
  echo "ABBRUCH: ShellyLanMan läuft gerade aus $ROOT/dist (PID: ${RUNNING//$'\n'/ })." >&2
  echo "         Der Build würde das laufende Bundle löschen." >&2
  echo "         Erst die App beenden (Menüleiste -> Beenden), dann erneut bauen." >&2
  exit 1
fi

if [[ ! -x "$VENDORED/shellylanman" || ! -f "$VENDORED/shellylanman.version" ]]; then
  echo "error: $VENDORED/shellylanman not found — run Scripts/build-server.sh first." >&2
  exit 1
fi
SERVER_VERSION="$(sed -n 1p "$VENDORED/shellylanman.version")"
SERVER_COMMIT="$(sed -n 2p "$VENDORED/shellylanman.version")"

# SDK explizit auf die stabile macOS-26-Reihe pinnen. Ein macOS-27-Beta-SDK
# hat sich als Default eingenistet (Symlink MacOSX.sdk -> MacOSX27.0.sdk);
# dessen SwiftUI-Makro-Plugin fehlt, `swift build` bricht dann mit
# "SwiftUIMacros.StateMacro could not be found" ab (Fix aus ha-screentime).
CLT_SDKS="/Library/Developer/CommandLineTools/SDKs"
if [[ -d "$CLT_SDKS/MacOSX26.sdk" ]]; then
  export SDKROOT="$CLT_SDKS/MacOSX26.sdk"
  echo "==> SDKROOT gepinnt: $(readlink -f "$SDKROOT" 2>/dev/null || echo "$SDKROOT")"
fi

echo "==> Building release executable"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/ShellyLanMan"

echo "==> Assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :ShellyLanManServerVersion string $SERVER_VERSION ($SERVER_COMMIT)" "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/ShellyLanMan"
cp "$VENDORED/shellylanman" "$APP/Contents/Helpers/shellylanman"
[[ -f "$ROOT/Resources/AppIcon.icns" ]] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"

echo "==> Code signing (identity: $IDENTITY)"
# Inside-out: the helper binary, then the app executable, then the bundle.
sign() {
  codesign --force --options runtime --timestamp=none -s "$IDENTITY" "$1"
}
sign "$APP/Contents/Helpers/shellylanman"
sign "$APP/Contents/MacOS/ShellyLanMan"
sign "$APP"

echo "==> Verifying signature"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Done: $APP (ShellyLanMan $SERVER_VERSION)"
echo "    Run with: open \"$APP\"   (look for the light-switch icon in the menu bar)"
