# TAS2783 Stereo Audio on ASUS ProArt PX13 (HN7306) — Linux 7.1+

Working **stereo** on built-in speakers of the ASUS ProArt PX13 (HN7306EA/EAC, AMD Strix Halo) — Linux kernel 7.1 and later, surviving kernel and alsa-ucm-conf updates.

**Tested on**: CachyOS 7.1.3, Arch, Fedora. Should work on any distro with systemd + alsa-ucm-conf.

---

## The Problem

Stock Linux 7.1+ TI `tas2783-sdw` driver on the PX13 initializes both smart amps with the same DSP cluster index (`0x01`), causing mono playback from one random speaker. The ACPI tables carry no SDCA/DisCo function data, so the driver can't auto-assign channels.

Additionally:
- The machine driver doesn't tag `spk:tas2783` in card components → UCM never selects the Speaker device.
- The AMD SoundWire controller doesn't survive suspend/resume.

---

## The Fix (4 components)

| Component | Problem Solved | How |
|-----------|---|---|
| **DKMS Module** | Both amps at same cluster index | Adds `Channel Playback` control (Left/Right per amp) + rebases nealstar's patch onto stock 7.1 driver |
| **UCM Profiles** | No Speaker device in HiFi profile | Defines tas2783 Speaker device + overrides to force codec selection |
| **Suspend Hook** | Audio dead after sleep | PCI remove+rescan of ACP device (only method that fully re-attaches peripherals) |
| **HiFi Activator** | Card defaults to stereo / wrong profile after boot | User service retries `pactl set-card-profile ... HiFi` after PipeWire starts |

---

## Quick Install

```bash
git clone https://github.com/ftoleedo/px13-audio-fix.git && cd px13-audio-fix

# Extract firmware blobs from ASUS Windows driver if needed
# (linux-firmware >= 20260519 may already have them)
# See "Firmware" section below

./install.sh                      # installs DKMS + UCM + hook
# Or just: ./install.sh firmware  # firmware only
```

**Then**: reboot, log back in, and test audio. The installer also does one live SoundWire reprobe so PipeWire rebuilds the card against the new UCM data, and it enables a user service that re-selects `HiFi` after PipeWire starts.

---

## What Gets Installed

| Path | Purpose | Notes |
|------|---------|-------|
| `/usr/src/snd-soc-tas2783-sdw-px13-1.0/` | DKMS kernel module | Auto-rebuilds on kernel updates |
| `/usr/share/alsa/ucm2/sof-soundwire/tas2783.conf` | Speaker device for HiFi profile | Sets Left/Right channels per amp |
| `/usr/share/alsa/ucm2/sof-soundwire/acp-dmic.conf` | Built-in DMIC capture device | |
| `/usr/share/alsa/ucm2/conf.d/amd-soundwire/<longname>.conf` | Codec override (unowned by packages) | Installed for the detected card longname |
| `/usr/share/alsa/ucm2/conf.d/amd-soundwire/ASUSTeKCOMPUTERINC.-ProArtPX13HN7306EA-1.0-HN7306EA.conf` | Fallback codec override | Covers PX13 EA cold boots before exact longname detection succeeds |
| `/usr/share/alsa/ucm2/conf.d/amd-soundwire/ASUSTeKCOMPUTERINC.-ProArtPX13HN7306EAC-1.0-HN7306EAC.conf` | Fallback codec override | Covers PX13 EAC cold boots before exact longname detection succeeds |
| `/lib/firmware/ti/audio/tas2783/1714-1-*.bin` | TAS2783 calibration firmware | Symlinked from top-level for driver |
| `/usr/lib/systemd/system-sleep/50-px13-soundwire` | Post-resume recovery hook | PCI reset for full re-initialization |
| `/usr/lib/systemd/scripts/50-px13-soundwire-boot.sh` | Boot-time SoundWire init script | Runs PCI cycle on cold boot if peripherals not attached |
| `/etc/systemd/system/50-px13-soundwire-boot.service` | Boot-time initialization service | Enabled at sysinit.target; runs before user sessions |
| `/usr/local/libexec/px13-set-hifi-profile` | HiFi profile helper | Retries until the AMD SoundWire card is ready |
| `/etc/systemd/user/px13-set-hifi-profile.service` | Login-time HiFi selection | Enabled globally and started for the current user |

---

## Firmware

If your distro ships `linux-firmware >= 20260519` (released 2026-05-19):
- Blobs already present as `ti/audio/tas2783/1714-1-0x8.bin` / `1714-1-0xB.bin`
- The installer will symlink them to the bare names the 7.1 kernel requests

If not (e.g., Ubuntu 26.04 with linux-firmware 20260319):
- Extract from ASUS Windows driver: `SmartAMP_TI_*.exe`
  - 7z x the .exe or run it on Windows, find `TI Smart Amplifier Driver` installer
  - Locate `Firmwares\1714-1-0x8.bin` and `1714-1-0xB.bin`
  - Rename to `1714-1-8.bin` and `1714-1-B.bin` (drop the `0x`)
  - Place them in the repo's `firmware/` directory
  - Run `./install.sh firmware`

**SHA-256 (ASUS V6.3.1.15):**
- `1714-1-8.bin`:  `9a105de50978fc3250062d66bea6b77f3aaabaf85280739be28ff1ed3ae535ca`
- `1714-1-B.bin`:  `a975dc7e2340cb5c97259d5e8c3d7e447b5a0af1a91528c058c9fda0adeb74c1`

Newer ASUS drivers may ship re-calibrated blobs (different SHA-256); that's fine — use your model's current blobs.

---

## Verify

```bash
# Module loaded?
modinfo -k $(uname -r) snd_soc_tas2783_sdw | grep filename
#  -> should show /lib/modules/.../updates/... (DKMS or manual build)

# Channel Playback control present?
amixer -D hw:1 cget name='tas2783-1 Channel Playback'
#  -> should show: values=1 (Left)
amixer -D hw:1 cget name='tas2783-2 Channel Playback'
#  -> should show: values=2 (Right)

# Active profile is HiFi with 2 sinks?
pactl list cards | grep -A5 'Active Profile'
#  -> should show: HiFi (with "sinks: 2")

# HiFi activator installed and enabled?
systemctl --user status px13-set-hifi-profile.service

# Stereo test (voice L/R from correct side)
speaker-test -D pulse -c2 -l1 -t wav
```

If left/right are physically swapped, edit `/usr/share/alsa/ucm2/sof-soundwire/tas2783.conf`:
- Change `cset "name='tas2783-1 Channel Playback' 1"` to `2` (Right)
- Change `cset "name='tas2783-2 Channel Playback' 2"` to `1` (Left)
- Restart: `systemctl --user restart pipewire wireplumber`

---

## Suspend/Resume

With the hook installed, audio should survive suspend:

```bash
systemctl suspend
# ...wait 15 seconds...
# Audio reappears, devices may flicker briefly during re-attach
journalctl -u 50-px13-soundwire -b --no-pager  # check logs
```

Logs written to `/var/log/px13-soundwire-resume.log`.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| "Dummy Output" / no Speaker after boot | SoundWire peripherals not attached on cold boot (now auto-recovered) | Check `journalctl -u 50-px13-soundwire-boot.service` for recovery logs; if still failing, run `sudo systemctl restart 50-px13-soundwire-boot.service` manually |
| Mono / one speaker | Stock module loaded instead of DKMS | Check `modinfo -k $(uname -r) snd_soc_tas2783_sdw` — must show `updates/` path |
| Card shows up as stereo/default profile | `HiFi` is missing for the card longname, or PipeWire picked the default profile before the card was ready | Check `cat /proc/asound/cards` and confirm the matching override exists under `/usr/share/alsa/ucm2/conf.d/amd-soundwire/`, then run `systemctl --user start px13-set-hifi-profile.service` |
| "Invalid argument" or profile stuck | PipeWire state corrupted | `pactl set-card-profile alsa_card.pci-0000_c4_00.5-platform-amd_sdw HiFi` |
| Kernel update breaks sound | DKMS failed to rebuild | Manually: `cd /usr/src/snd-soc-tas2783-sdw-px13-1.0 && sudo make install KVER=$(uname -r)` |
| Suspend hook won't run | systemd-sleep hook not installed or wrong permissions | `ls -l /usr/lib/systemd/system-sleep/50-px13-soundwire` (must be `-rwxr-xr-x`) |

---

## Uninstall

```bash
# Module
sudo dkms remove snd-soc-tas2783-sdw-px13/1.0 -k $(uname -r) 2>/dev/null || \
  sudo rm -f /lib/modules/$(uname -r)/updates/snd-soc-tas2783-sdw.ko

# UCM
sudo rm /usr/share/alsa/ucm2/sof-soundwire/tas2783.conf
sudo rm /usr/share/alsa/ucm2/sof-soundwire/acp-dmic.conf
LONG="$(awk '/amd-soundwire/{getline; gsub(/ /,""); print; exit}' /proc/asound/cards)"
sudo rm "/usr/share/alsa/ucm2/conf.d/amd-soundwire/$LONG.conf"
sudo rm "/usr/share/alsa/ucm2/conf.d/amd-soundwire/ASUSTeKCOMPUTERINC.-ProArtPX13HN7306EA-1.0-HN7306EA.conf"
sudo rm "/usr/share/alsa/ucm2/conf.d/amd-soundwire/ASUSTeKCOMPUTERINC.-ProArtPX13HN7306EAC-1.0-HN7306EAC.conf"

# Hook
sudo rm /usr/lib/systemd/system-sleep/50-px13-soundwire
# Boot-time initialization (if installed)
sudo systemctl disable --now 50-px13-soundwire-boot.service 2>/dev/null || true
sudo rm /etc/systemd/system/50-px13-soundwire-boot.service
sudo rm /usr/lib/systemd/scripts/50-px13-soundwire-boot.sh

# HiFi activator
systemctl --user disable --now px13-set-hifi-profile.service 2>/dev/null || true
sudo systemctl --global disable px13-set-hifi-profile.service 2>/dev/null || true
sudo rm /etc/systemd/user/px13-set-hifi-profile.service
sudo rm /usr/local/libexec/px13-set-hifi-profile

# Firmware (optional; can leave for other distros)
sudo rm /lib/firmware/1714-1-*.bin /lib/firmware/FFFF-1-*.bin
sudo rm -rf /lib/firmware/ti/audio/tas2783

# Restart audio
systemctl --user restart pipewire wireplumber
```

---

## Upstream Status

The `Channel Playback` control and UCM speaker codec tagging belong in the mainline kernel and alsa-ucm-conf. Tracking: [CachyOS/linux-cachyos#737](https://github.com/CachyOS/linux-cachyos/issues/737).

---

## Credits

- **nealstar** — channel-selection control (original 16-patch series)
- **brainchillz** — suspend/resume PCI reset approach + UCM analysis
- **AlexanderBartash** — comprehensive testing on Ubuntu 26.04 stock kernel 7.0, documented post-resume recovery
- **TI** — upstream tas2783 driver

## License

Guide and scripts: CC0. Kernel module: GPL-2.0 (derived from upstream).
