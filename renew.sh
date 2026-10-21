#!/bin/bash
# Re-signs and reinstalls TubeShell on the iPhone before the free 7-day signature
# runs out. launchd runs it every hour; it does nothing until fewer than
# RENEW_DAYS days are left, then retries each hour until the iPhone is reachable
# (cable, or same wifi as the Mac).
#
#   ./renew.sh                  check and renew if due (what launchd runs)
#   ./renew.sh --force          renew now
#   ./renew.sh --install-agent  install the hourly launchd job
#   ./renew.sh --remove-agent   remove it
set -euo pipefail
cd "$(dirname "$0")"

# Your iPhone's identifier goes in renew.local (not committed), e.g.
#   DEVICE=00008130-000000000000001C
# List yours with: xcrun devicectl list devices
# If you changed the Bundle Identifier, set BUNDLE=<yours> there too.
DEVICE=""
BUNDLE=es.personal.tubeshell
[ -f renew.local ] && . ./renew.local
if [ -z "$DEVICE" ]; then
  echo "Falta renew.local con DEVICE=<identificador del iPhone> (xcrun devicectl list devices)" >&2
  exit 1
fi
RENEW_DAYS=2

LABEL=es.personal.tubeshell.renew
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
SUPPORT="$HOME/Library/Application Support/TubeShell"
STATE="$SUPPORT/installed-expiry"   # epoch seconds when the installed copy expires
NAGGED="$SUPPORT/last-warning"
LOG="$HOME/Library/Logs/TubeShell-renew.log"
PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
APP=build/Build/Products/Debug-iphoneos/TubeShell.app

log() { echo "$(date '+%F %T') $*" >>"$LOG"; }
notify() { osascript -e "display notification \"$1\" with title \"Tube\"" >/dev/null 2>&1 || true; }
profile_plist() { security cms -D -i "$1" 2>/dev/null; }
# Warns with $1, only in the last day and at most every 6 hours.
nag() {
  if ((expiry - now < 86400)) && [ -z "$(find "$NAGGED" -mmin -360 2>/dev/null)" ]; then
    notify "$1"
    touch "$NAGGED"
  fi
}

case "${1:-}" in
  --install-agent)
    mkdir -p "$(dirname "$AGENT")"
    cat >"$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$PWD/renew.sh</string></array>
  <key>StartInterval</key><integer>3600</integer>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$AGENT"
    echo "Instalado: se comprueba cada hora. Registro: $LOG"
    exit 0
    ;;
  --remove-agent)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$AGENT"
    echo "Quitado."
    exit 0
    ;;
esac

mkdir -p "$SUPPORT"
now=$(date +%s)
expiry=$(cat "$STATE" 2>/dev/null || echo 0)

if [ "${1:-}" != "--force" ] && ((expiry - now > RENEW_DAYS * 86400)); then
  exit 0
fi

# "connected", "available" or "available (paired)"; never "unavailable".
if ! xcrun devicectl list devices 2>/dev/null | grep "$DEVICE" | grep -qE '[[:space:]](connected|available)'; then
  log "iPhone not reachable, will retry"
  nag "La firma caduca pronto. Conecta el iPhone (cable o misma wifi) y desbloquéalo para renovarla."
  exit 0
fi

log "renewing"

# Drop the cached profile so Xcode asks Apple for a fresh 7-day one.
for f in "$PROFILES"/*.mobileprovision; do
  [ -e "$f" ] || continue
  if profile_plist "$f" | plutil -extract Name raw -o - - 2>/dev/null | grep -q ": $BUNDLE\$"; then
    rm -f "$f"
  fi
done

if ! xcodebuild -project TubeShell.xcodeproj -scheme TubeShell -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath build -allowProvisioningUpdates \
  build >>"$LOG" 2>&1; then
  log "build failed"
  notify "No se pudo renovar: falló la compilación. Mira $LOG"
  exit 1
fi

if ! xcrun devicectl device install app --device "$DEVICE" "$APP" >>"$LOG" 2>&1; then
  log "install failed, will retry"
  nag "No se pudo instalar la renovación. Desbloquea el iPhone y déjalo conectado."
  exit 0
fi

if ! iso=$(profile_plist "$APP/embedded.mobileprovision" | plutil -extract ExpirationDate raw -o - -); then
  log "installed, but could not read the new expiry date"
  exit 0
fi
date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s >"$STATE"
log "installed, signature valid until $iso"
notify "Firma renovada. Válida hasta $(date -j -r "$(cat "$STATE")" '+%d/%m %H:%M')."
