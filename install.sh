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
DEFAULT_LONGS=(
  "ASUSTeKCOMPUTERINC.-ProArtPX13HN7306EA-1.0-HN7306EA"
  "ASUSTeKCOMPUTERINC.-ProArtPX13HN7306EAC-1.0-HN7306EAC"
)

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

  local F8="$REPO/firmware/1714-1-8.bin" FB="$REPO/firmware/1714-1-B.bin"
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

  # If card not enumerated yet, install the known PX13 longname fallbacks.
  if [ -z "$LONG" ]; then
    LONG="${DEFAULT_LONGS[0]}"
    warn "Card not enumerated yet; installing fallback longname overrides"
    warn "Boot-time HiFi activator will retry once the card appears"
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

  # Longname override: forces speaker codec selection with the tested syntax.
  # Install both the detected longname and the known PX13 fallback so cold boots
  # do not depend on re-running the installer after the card enumerates.
  sudo install -Dm0644 "$REPO/configs/px13-longname-override.conf" \
    "$UCM/conf.d/amd-soundwire/$LONG.conf"
  ok "conf.d/amd-soundwire/$LONG.conf (override, survives updates)"

  for fallback_long in "${DEFAULT_LONGS[@]}"; do
    [ "$fallback_long" = "$LONG" ] && continue
    sudo install -Dm0644 "$REPO/configs/px13-longname-override.conf" \
      "$UCM/conf.d/amd-soundwire/$fallback_long.conf"
    ok "conf.d/amd-soundwire/$fallback_long.conf (fallback override)"
  done

  hdr "Installing suspend/resume recovery hook"
  sudo install -m0755 "$REPO/50-px13-soundwire" /usr/lib/systemd/system-sleep/
  ok "systemd-sleep hook installed"
  hdr "Installing boot-time SoundWire initialization"
  sudo install -Dm0755 "$REPO/50-px13-soundwire-boot.sh" /usr/lib/systemd/scripts/50-px13-soundwire-boot.sh
  sudo install -Dm0644 "$REPO/50-px13-soundwire-boot.service" /etc/systemd/system/50-px13-soundwire-boot.service
  if systemctl enable --now 50-px13-soundwire-boot.service >/dev/null 2>&1; then
    ok "Boot-time initialization service enabled"
  else
    warn "Could not enable boot-time service (will run on next reboot)"
  fi

  hdr "Installing HiFi profile activator"
  sudo install -Dm0755 "$REPO/px13-set-hifi-profile" /usr/local/libexec/px13-set-hifi-profile
  sudo install -Dm0644 "$REPO/px13-set-hifi-profile.service" /etc/systemd/user/px13-set-hifi-profile.service
  if systemctl --global enable px13-set-hifi-profile.service >/dev/null 2>&1; then
    ok "Global user service enabled"
  else
    warn "Could not enable global user service; enabling for current user only"
  fi

  systemctl --user daemon-reload 2>/dev/null || true
  if systemctl --user enable --now px13-set-hifi-profile.service >/dev/null 2>&1; then
    ok "HiFi profile activator started for current user"
  else
    warn "Could not start HiFi activator for current user"
  fi

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

  # Force one full SoundWire reprobe so PipeWire rebuilds the card profiles
  # against the newly installed UCM data instead of keeping stale pro-audio
  # state until the next suspend/resume or reboot.
  if sudo /usr/lib/systemd/system-sleep/50-px13-soundwire post suspend; then
    ok "SoundWire card reprobed and audio services refreshed"
  else
    warn "SoundWire reprobe failed; falling back to PipeWire restart"
    systemctl --user restart wireplumber pipewire pipewire-pulse
    sleep 3

    # Try to switch to HiFi now as well; the user service will retry on boot/login.
    /usr/local/libexec/px13-set-hifi-profile || \
      warn "Could not switch to HiFi yet (card may not be ready yet)"
  fi

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
