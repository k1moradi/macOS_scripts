#!/bin/zsh
set -o pipefail

# Quick drop-in script for rapid testing.
# Save as ~/bin/brew_maintenance.sh, make executable: chmod +x ~/bin/brew_maintenance.sh
# Run interactively with --force to bypass checks: ~/bin/brew_maintenance.sh --force

BREW=/usr/local/bin/brew
LOG="$HOME/brewupdate.log"
WORKDIR="$HOME"
ALLOWED_SSIDS=("HomeNetwork" "MyOfficeWiFi")   # edit to your trusted SSIDs
SKIP_ON_BATTERY=true
SKIP_ON_LOW_POWER=true
SKIP_ON_UNKNOWN_SSID=true

# parse args
FORCE=false
for a in "$@"; do
  case "$a" in
    --force) FORCE=true ;;
  esac
done

# logging helper: always append to log; also print to terminal when interactive
log() {
  local msg="$*"
  echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" >> "$LOG"
  if [ -t 1 ]; then
    echo "$msg"
  fi
}

# refuse running as root (Homebrew should run as your user)
if [ "$(id -u)" -eq 0 ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') Refusing to run as root. Run as your normal user." >> "$LOG"
  echo "Refusing to run as root. Run as your normal user." >&2
  exit 1
fi

# ensure safe working directory (fixes launchd/root-readable errors)
cd "$WORKDIR" || { log "Cannot cd to $WORKDIR"; exit 1; }

log "Starting brew maintenance (force=$FORCE)"

# power checks
is_on_battery() {
  pmset -g batt 2>/dev/null | grep -q "Now drawing from.*Battery"
}
is_low_power_mode() {
  pmset -g 2>/dev/null | awk '/lowpowermode/ {print $2}' | grep -q '^1$'
}

if [ "$FORCE" = false ]; then
  if $SKIP_ON_BATTERY && is_on_battery; then
    log "Skipping: running on battery"
    exit 0
  fi
  if $SKIP_ON_LOW_POWER && is_low_power_mode; then
    log "Skipping: Low Power Mode is enabled"
    exit 0
  fi
fi

# wifi helpers
get_wifi_device() {
  networksetup -listallhardwareports 2>/dev/null | awk '/Wi-Fi|AirPort/{getline; print $2; exit}'
}
get_current_ssid() {
  local dev raw ssid
  dev=$(get_wifi_device)
  if [ -z "$dev" ]; then
    echo ""
    return
  fi
  raw=$(networksetup -getairportnetwork "$dev" 2>/dev/null)
  ssid=${raw#Current Wi-Fi Network: }
  case "$ssid" in
    ""|"You are not associated with an AirPort network."|"You are not associated with an AirPort network") echo "" ;;
    *) echo "$ssid" ;;
  esac
}

if [ "$FORCE" = false ] && $SKIP_ON_UNKNOWN_SSID; then
  SSID=$(get_current_ssid)
  if [ -z "$SSID" ]; then
    log "No Wi‑Fi SSID detected. Treating as metered/untrusted network; skipping to preserve bandwidth"
    exit 0
  fi
  allowed=false
  for s in "${ALLOWED_SSIDS[@]}"; do
    if [ "$s" = "$SSID" ]; then allowed=true; break; fi
  done
  if ! $allowed; then
    log "Connected to SSID '$SSID' which is not in whitelist; skipping to preserve bandwidth"
    exit 0
  fi
  log "Connected to SSID '$SSID' (whitelisted)"
fi

# run Homebrew maintenance; mirror output to terminal and log
{
  "$BREW" update
  "$BREW" upgrade
  "$BREW" autoremove
  "$BREW" cleanup
} 2>&1 | tee -a "$LOG"

# capture exit status of left side of pipe (zsh)
STATUS=${pipestatus[1]:-$?}

if [ $STATUS -eq 0 ]; then
  osascript -e 'display notification "Homebrew maintenance completed successfully." with title "BrewUpdate"'
else
  osascript -e 'display notification "Homebrew maintenance encountered errors. Check brewupdate.log." with title "BrewUpdate"'
fi

log "Finished with status $STATUS"
exit $STATUS
