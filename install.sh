#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UCM_ROOT=/usr/share/alsa/ucm2
LONGNAME=ASUSTeKCOMPUTERINC.-ProArtPX13HN7306EAC-1.0-HN7306EAC
CARD_NUM=1
CARD_NAME=alsa_card.pci-0000_c4_00.5-platform-amd_sdw
DKMS_NAME=snd-soc-tas2783-sdw-px13
DKMS_VER=1.0
KREL="$(uname -r)"
HOOK_DIR=/lib/systemd/system-sleep
HOOK_PATH="$HOOK_DIR/50-px13-soundwire"

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: missing required command: $1" >&2
        exit 1
    }
}

kernel_ok() {
    local major minor
    major="${KREL%%.*}"
    minor="${KREL#*.}"
    minor="${minor%%.*}"
    [[ "$major" -gt 7 ]] || [[ "$major" -eq 7 && "$minor" -ge 1 ]]
}

ensure_module() {
    local module_path

    module_path="$(modinfo -k "$KREL" snd_soc_tas2783_sdw -F filename 2>/dev/null || true)"
    if [[ "$module_path" == *"/updates/"* ]]; then
        echo "==> Patched TAS2783 module already active: $module_path"
        return 0
    fi

    echo "==> Installing patched TAS2783 module"
    if command -v dkms >/dev/null 2>&1; then
        sudo mkdir -p "/usr/src/$DKMS_NAME-$DKMS_VER"
        sudo cp -f "$REPO/module/tas2783-sdw.c" "$REPO/module/tas2783.h" \
                   "$REPO/module/Makefile" "$REPO/module/dkms.conf" \
                   "/usr/src/$DKMS_NAME-$DKMS_VER/"
        sudo dkms install --force "$DKMS_NAME/$DKMS_VER" -k "$KREL"
    else
        need_cmd make
        echo "    dkms not found; building a one-kernel local module"
        ( cd "$REPO/module" && make KVER="$KREL" LLVM=1 )
        sudo install -Dm644 "$REPO/module/snd-soc-tas2783-sdw.ko" \
            "/lib/modules/$KREL/updates/snd-soc-tas2783-sdw.ko"
        sudo depmod -a "$KREL"
    fi

    if lsmod | grep -q '^snd_soc_tas2783_sdw'; then
        sudo modprobe -r snd_soc_tas2783_sdw || true
    fi
    sudo modprobe snd_soc_tas2783_sdw
}

install_ucm() {
    echo "==> Installing Mint-compatible UCM files"
    sudo install -Dm644 "$REPO/configs/sof-soundwire_tas2783.conf" \
        "$UCM_ROOT/sof-soundwire/tas2783.conf"
    sudo install -Dm644 "$REPO/configs/codecs_tas2783_init.conf" \
        "$UCM_ROOT/codecs/tas2783/init.conf"
    sudo install -Dm644 "$REPO/configs/px13-longname-override.conf" \
        "$UCM_ROOT/conf.d/amd-soundwire/$LONGNAME.conf"
}

install_resume_hook() {
    echo "==> Installing SoundWire resume hook"
    sudo install -Dm755 "$REPO/50-px13-soundwire" "$HOOK_PATH"
}

validate_ucm() {
    local ucm_devices

    echo "==> Validating HiFi devices"
    ucm_devices="$(alsaucm -c "$CARD_NUM" list _devices/HiFi 2>/dev/null || true)"
    printf '%s\n' "$ucm_devices" | sed 's/^/    /'
    if ! printf '%s\n' "$ucm_devices" | grep -q 'Speaker'; then
        echo "ERROR: UCM did not expose a Speaker device on card $CARD_NUM" >&2
        exit 1
    fi
}

restart_audio() {
    echo "==> Restarting PipeWire and selecting HiFi"
    systemctl --user restart wireplumber pipewire pipewire-pulse
    sleep 2
    pactl set-card-profile "$CARD_NAME" HiFi || true
}

apply_channel_map() {
    echo "==> Setting TAS2783 channels"
    amixer -D "hw:$CARD_NUM" cset name='tas2783-1 Channel Playback' Left >/dev/null
    amixer -D "hw:$CARD_NUM" cset name='tas2783-2 Channel Playback' Right >/dev/null
    amixer -D "hw:$CARD_NUM" cget name='tas2783-1 Channel Playback' | tail -1 | sed 's/^/    /'
    amixer -D "hw:$CARD_NUM" cget name='tas2783-2 Channel Playback' | tail -1 | sed 's/^/    /'
}

set_default_sink() {
    local sink_id

    sink_id="$(wpctl status | awk '/Audio Coprocessor Speaker/ {gsub(/[^0-9]/, "", $1); print $1; exit}')"
    if [[ -n "$sink_id" ]]; then
        wpctl set-default "$sink_id" || true
        echo "==> Default sink set to Audio Coprocessor Speaker ($sink_id)"
    fi
}

persist_state() {
    echo "==> Saving ALSA state"
    sudo alsactl store || true
}

print_summary() {
    echo
    echo "Verification"
    echo "  modinfo -k $(uname -r) snd_soc_tas2783_sdw -F filename"
    echo "  pactl list cards | grep 'Active Profile'"
    echo "  speaker-test -D pulse -c2 -l1 -t wav"
    echo
    echo "If left/right are reversed, swap the two Channel Playback values in"
    echo "  $UCM_ROOT/sof-soundwire/tas2783.conf"
    echo "then run: systemctl --user restart pipewire wireplumber"
}

main() {
    need_cmd alsaucm
    need_cmd amixer
    need_cmd modinfo
    need_cmd pactl
    need_cmd wpctl

    if ! kernel_ok; then
        echo "ERROR: kernel $KREL is too old; this path needs 7.1 or newer" >&2
        exit 1
    fi

    ensure_module
    install_ucm
    install_resume_hook
    validate_ucm
    restart_audio
    apply_channel_map
    set_default_sink
    persist_state
    print_summary
}

main "$@"