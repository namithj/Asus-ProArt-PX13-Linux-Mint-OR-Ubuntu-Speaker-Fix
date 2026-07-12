#!/usr/bin/env bash
#
# install.sh — ASUS ProArt PX13 (HN7306) audio on Linux 7.1+
#
# Installs:
#   - DKMS module with Channel Playback control (stereo fix for stock TI driver)
#   - UCM configs for Speaker device + HiFi profile
#   - systemd-sleep hook for suspend/resume recovery
#
# Usage:
#   ./install.sh              # standard install (DKMS + UCM + hook)
#   ./install.sh firmware     # install firmware blobs only (if not in linux-firmware)
#

set -euo pipefail

RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
err()  { printf '%s✗%s %s\n' "$RED"    "$RESET" "$*" >&2; exit 1; }
ok()   { printf '%s✓%s %s\n' "$GREEN"  "$RESET" "$*"; }
warn() { printf '%s!%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
hdr()  { printf '\n%s%s%s\n' "$BOLD"   "$*" "$RESET"; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KVER="$(uname -r)"
KMAJ="${KVER%%.*}"
KMIN="${KVER#*.}"; KMIN="${KMIN%%.*}"

# Preflight
hdr "PX13 Audio Fix — kernel $KVER"
if [ "$KMAJ" -lt 7 ] || ([ "$KMAJ" -eq 7 ] && [ "$KMIN" -lt 1 ]); then
  err "Kernel 7.1+ required (you have $KVER)"
fi
ok "Kernel version check passed"

command -v systemctl >/dev/null || err "systemd required"
sudo -v || err "Need sudo"

# ============ Firmware (optional, may already be in linux-firmware) ============
install_firmware() {
  hdr "Installing firmware blobs"

  local F8="$REPO/1714-1-8.bin" FB="$REPO/1714-1-B.bin"
  [ -f "$F8" ] || err "Missing: $F8 (extract from ASUS Windows driver)"
  [ -f "$FB" ] || err "Missing: $FB (extract from ASUS Windows driver)"

  # Verify SHA-256
  local SHA8="9a105de50978fc3250062d66bea6b77f3aaabaf85280739be28ff1ed3ae535ca"
  local SHAB="a975dc7e2340cb5c97259d5e8c3d7e447b5a0af1a91528c058c9fda0adeb74c1"

  if [ "$(sha256sum "$F8" | cut -d' ' -f1)" = "$SHA8" ] && \
     [ "$(sha256sum "$FB" | cut -d' ' -f1)" = "$SHAB" ]; then
    ok "Firmware matches ASUS V6.3.1.15"
  else
    warn "SHA-256 differs (OK if from newer ASUS driver for THIS model)"
  fi

  # Install under linux-firmware convention + symlinks
  sudo install -d -m0755 /lib/firmware/ti/audio/tas2783
  sudo install -m0644 "$F8" /lib/firmware/ti/audio/tas2783/1714-1-8.bin
  sudo install -m0644 "$FB" /lib/firmware/ti/audio/tas2783/1714-1-B.bin
  sudo ln -sf ti/audio/tas2783/1714-1-8.bin /lib/firmware/1714-1-8.bin
  sudo ln -sf ti/audio/tas2783/1714-1-B.bin /lib/firmware/1714-1-B.bin

  # FFFF aliases (driver may request these during re-probe)
  sudo ln -sf ti/audio/tas2783/1714-1-8.bin /lib/firmware/FFFF-1-8.bin
  sudo ln -sf ti/audio/tas2783/1714-1-B.bin /lib/firmware/FFFF-1-B.bin

  ok "Firmware installed"
}

# ============ DKMS module + UCM + hook ============
install_all() {
  hdr "Installing DKMS module"

  DKMS_NAME="snd-soc-tas2783-sdw-px13"
  DKMS_VER="1.0"
  KREL="$KVER"

  # Clean up any old manual build
  sudo rm -f "/lib/modules/$KREL/updates/snd-soc-tas2783-sdw.ko" 2>/dev/null || true

  if command -v dkms >/dev/null; then
    sudo mkdir -p "/usr/src/$DKMS_NAME-$DKMS_VER"
    sudo cp "$REPO/module/"* "/usr/src/$DKMS_NAME-$DKMS_VER/"
    sudo dkms install --force "$DKMS_NAME/$DKMS_VER" -k "$KREL" 2>&1 | grep -v '^At' | sed 's/^/  /'
    ok "DKMS installed (auto-rebuilds on kernel updates)"
  else
    warn "dkms not installed; manual build fallback"
    (cd "$REPO/module" && make KVER="$KREL" LLVM=1)
    sudo install -Dm644 "$REPO/module/snd-soc-tas2783-sdw.ko" \
      "/lib/modules/$KREL/updates/snd-soc-tas2783-sdw.ko"
    sudo depmod -a "$KREL"
    warn "Module installed manually — rebuild needed on next kernel update"
  fi

  hdr "Installing UCM configs"

  UCM=/usr/share/alsa/ucm2
  [ -d "$UCM" ] || err "UCM directory not found: $UCM"

  # Derive card longname (needed for the override path)
  local LONG
  LONG="$(awk '/amd-soundwire/{getline; gsub(/^ +| +$/,""); gsub(/ /,""); print; exit}' /proc/asound/cards 2>/dev/null || echo '')"

  # If card not enumerated yet, use a default (will be re-derived after first boot)
  if [ -z "$LONG" ]; then
    LONG="ASUSTeKCOMPUTERINC.-ProArtPX13HN7306EAC-1.0-HN7306EAC"
    warn "Card not enumerated yet; using default longname"
    warn "Re-run this script after first boot to derive the exact name"
  fi

  # Speaker device config (PCM hw:X,2)
  sudo install -m0644 "$REPO/configs/sof-soundwire_tas2783.conf" \
    "$UCM/sof-soundwire/tas2783.conf"
  ok "tas2783.conf (Speaker device)"

  # DMIC device config (PCM hw:X,4)
  sudo install -m0644 "$REPO/configs/sof-soundwire_acp-dmic.conf" \
    "$UCM/sof-soundwire/acp-dmic.conf"
  ok "acp-dmic.conf (built-in microphone)"

  # tas2783 codec init.conf. The master sof-soundwire.conf does
  # Include /codecs/${SpeakerCodec1}/init.conf when the speaker codec is set;
  # the distro doesn't ship a tas2783 one, so a missing file would abort the
  # HiFi verb with -2. (acp-dmic's init.conf is shipped by alsa-ucm-conf.)
  sudo install -Dm0644 "$REPO/configs/codecs_tas2783_init.conf" \
    "$UCM/codecs/tas2783/init.conf"
  ok "codecs/tas2783/init.conf"

  # Longname override: forces speaker/mic codec selection
  # (Unowned path => survives alsa-ucm-conf updates)
  { cat "$UCM/conf.d/amd-soundwire/amd-soundwire.conf" 2>/dev/null || echo ""
    echo ""
    echo "Define.SpeakerCodec1 \"tas2783\""
    echo "Define.MicCodec1 \"acp-dmic\""
  } | sudo tee "$UCM/conf.d/amd-soundwire/$LONG.conf" >/dev/null
  ok "conf.d/amd-soundwire/$LONG.conf (override, survives updates)"

  hdr "Installing suspend/resume recovery hook"
  sudo install -m0755 "$REPO/50-px13-soundwire" /usr/lib/systemd/system-sleep/
  ok "systemd-sleep hook installed"

  hdr "Activating module and restarting audio"
  # Stop audio services to allow module reload
  systemctl --user stop wireplumber pipewire pipewire-pulse 2>/dev/null || true

  # Try to reload the module live (if already loaded)
  if lsmod | grep -q snd_soc_tas2783_sdw; then
    if sudo modprobe -r snd_soc_tas2783_sdw 2>/dev/null && \
       sudo modprobe snd_soc_tas2783_sdw; then
      ok "Module reloaded (live)"
      sleep 2
    else
      warn "Could not reload live — reboot required"
    fi
  fi

  # Restart PipeWire
  systemctl --user restart wireplumber pipewire pipewire-pulse
  sleep 3

  # Try to switch to HiFi profile
  local PCARD="alsa_card.pci-0000_c4_00.5-platform-amd_sdw"
  pactl set-card-profile "$PCARD" HiFi 2>/dev/null || \
    warn "Could not switch to HiFi (card may not be ready yet)"

  ok "Audio system restarted"

  hdr "Verification"
  echo "  Kernel module:"
  modinfo -k "$KREL" snd_soc_tas2783_sdw 2>/dev/null | grep -E 'filename|version' | sed 's/^/    /'

  echo ""
  echo "  Channel Playback controls (should show Left/Right):"
  for n in 1 2; do
    amixer -D hw:1 cget "name=tas2783-$n Channel Playback" 2>/dev/null | tail -1 | sed "s/^/    tas2783-$n: /" || true
  done

  echo ""
  echo "  Card profile (should be HiFi with 2 sinks):"
  pactl list cards 2>/dev/null | grep -A3 "Active Profile" | sed 's/^/    /' || true

  echo ""
  echo "  Verification complete. Next: reboot and test audio."
}

# ============ Main ============
case "${1:-}" in
  firmware) install_firmware ;;
  *)        install_all ;;
esac

hdr "Done"
echo "To uninstall: see README.md 'Uninstall' section"
