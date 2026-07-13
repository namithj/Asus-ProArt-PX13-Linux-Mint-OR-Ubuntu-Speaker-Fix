#!/bin/bash
#
# Boot-time SoundWire initialization for ASUS ProArt PX13 (HN7306)
#
# Runs at system boot to ensure AMD SoundWire peripherals are properly attached.
# Mirrors the suspend/resume recovery logic but triggers on cold start.
#
# Install: sudo install -Dm0755 this-file /usr/lib/systemd/scripts/50-px13-soundwire-boot.sh

set -u

PCI="0000:c4:00.5"
CARD_ID="amdsoundwire"
SDW_SLAVES="/sys/bus/soundwire/devices/sdw:0:1:*"
LOG="/var/log/px13-soundwire-resume.log"

log() { printf '[%s] %s\n' "$(date '+%F %T' 2>/dev/null || echo now)" "$*" >> "$LOG" 2>/dev/null; }

# Check if all SoundWire peripherals report "Attached"
all_attached() {
  local attached=0 total=0
  for d in $SDW_SLAVES; do
    [ -e "$d/status" ] || continue
    total=$((total + 1))
    [ "$(cat "$d/status" 2>/dev/null)" = "Attached" ] && attached=$((attached + 1))
  done
  [ "$total" -gt 0 ] && [ "$attached" -eq "$total" ]
}

sdw_status() {
  local s=""
  for d in $SDW_SLAVES; do
    [ -e "$d/status" ] || continue
    s="$s $(basename "$d" | cut -d: -f5-):$(cat "$d/status" 2>/dev/null)"
  done
  echo "$s"
}

# PCI remove + rescan (not driver unbind/bind)
pw() { timeout 15 sh -c "echo '$1' > '$2'" 2>/dev/null || true; }

log "=== boot-time SoundWire initialization ($PCI) ==="

# Check if already attached — skip recovery if hardware is healthy
if all_attached && grep -q "$CARD_ID" /proc/asound/cards 2>/dev/null; then
  log "SoundWire peripherals already attached; skipping recovery"
  exit 0
fi

log "SoundWire not fully initialized; running PCI cycle"

cycle=1
while [ $cycle -le 2 ]; do
  log "cycle $cycle: removing PCI device"
  [ -e "/sys/bus/pci/devices/$PCI" ] && pw 1 "/sys/bus/pci/devices/$PCI/remove"
  sleep 2

  log "cycle $cycle: rescanning PCI bus"
  pw 1 /sys/bus/pci/rescan

  # Wait for card to reappear
  i=0; while [ $i -lt 40 ]; do
    grep -q "$CARD_ID" /proc/asound/cards 2>/dev/null && break
    sleep 0.25; i=$((i + 1))
  done

  # Wait for peripherals to attach
  i=0; while [ $i -lt 24 ]; do
    all_attached && break
    sleep 0.5; i=$((i + 1))
  done

  log "cycle $cycle: status =$(sdw_status)"
  all_attached && break
  cycle=$((cycle + 1))
done

# Safety: never leave PCI device absent
if [ ! -e "/sys/bus/pci/devices/$PCI" ]; then
  log "WARNING: $PCI still missing; re-scanning"
  pw 1 /sys/bus/pci/rescan
fi

grep -q "$CARD_ID" /proc/asound/cards 2>/dev/null || \
  log "WARNING: amd-soundwire card did not reappear"
all_attached || log "WARNING: peripherals still not all attached"

# Restart PipeWire for each active user session (if any users are logged in)
sleep 2
for uid in $(loginctl list-users --no-legend 2>/dev/null | awk '{print $1}'); do
  rt="/run/user/$uid"
  [ -d "$rt" ] || continue

  user=$(id -nu "$uid" 2>/dev/null) || continue

  log "uid $uid: restarting PipeWire (boot recovery)"
  sudo -u "$user" XDG_RUNTIME_DIR="$rt" systemctl --user \
    restart wireplumber pipewire pipewire-pulse 2>>"$LOG" || \
    log "uid $uid: PipeWire restart failed"

  sudo -u "$user" XDG_RUNTIME_DIR="$rt" \
    /usr/local/libexec/px13-set-hifi-profile 2>>"$LOG" || \
    log "uid $uid: HiFi profile activation failed"
done

log "=== boot initialization complete ==="
exit 0
