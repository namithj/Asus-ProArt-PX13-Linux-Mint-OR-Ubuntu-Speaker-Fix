# ASUS ProArt PX13 speaker fix for Linux Mint

This folder is a Mint-only distribution of the PX13 speaker fix.

It targets the ASUS ProArt PX13 HN7306EA / HN7306EAC on Linux Mint 22.3 with a stock kernel `7.1` or newer. It is built around the same kernel-side TAS2783 fix used in the upstream PX13 audio project, but the userspace ALSA/UCM layer has been adjusted specifically for Mint's older `alsa-ucm-conf` stack.

## Credit

This Mint package is derived from the original PX13 audio fix by ftoleedo for CachyOS:

- https://github.com/ftoleedo/px13-audio-fix/

That repository established the working stock-kernel `7.1+` approach for the PX13 by combining the patched `snd_soc_tas2783_sdw` driver, TAS2783 UCM definitions, and the SoundWire resume hook. This Mint-only bundle keeps that core fix and adapts the userspace configuration to Linux Mint.

## What this fixes

On the PX13, stock kernels `7.1+` can load the TAS2783 speaker amps, but three problems remain:

1. The AMD SoundWire machine driver does not advertise the PX13 speaker codec in the way Mint's generic UCM expects, so the `Speaker` device never appears in the `HiFi` profile.
2. The stock TAS2783 driver initializes both amps to the same channel unless the patched driver with `Channel Playback` controls is used.
3. The AMD SoundWire controller can fail after suspend/resume unless a sleep hook rebinds it.

This bundle addresses all three:

1. It installs a Mint-compatible PX13 long-name UCM file in `Syntax 6` format.
2. It installs or reuses the patched `snd_soc_tas2783_sdw` module so amp 1 can be `Left` and amp 2 can be `Right`.
3. It installs a systemd sleep hook to recover SoundWire after suspend.

## Why Mint needs its own package

The upstream instructions were written around CachyOS and newer ALSA UCM behavior. On Linux Mint 22.3:

1. `alsa-ucm-conf 1.2.10` rejects the newer `Syntax 8` PX13 override.
2. The overlay-style `Append.Define` UCM override used upstream does not reliably produce a `Speaker` device on this stack.

The fix here replaces that overlay with a full PX13-specific `amd-soundwire` config that Mint parses correctly.

## Included files

- `install.sh`: Mint installer. Run this as your normal desktop user, not with `sudo`.
- `50-px13-soundwire`: suspend/resume recovery hook.
- `configs/px13-longname-override.conf`: Mint-compatible PX13 UCM card config.
- `configs/sof-soundwire_tas2783.conf`: `Speaker` device definition and stereo channel assignment.
- `configs/codecs_tas2783_init.conf`: TAS2783 mixer remap for the two-amp setup.
- `module/`: DKMS-capable patched TAS2783 SoundWire driver source.
- `LICENSE`: license inherited from the source project.

## Requirements

This guide assumes you are already booted into a working `7.1.x` kernel.

- ASUS ProArt PX13 HN7306EA or HN7306EAC
- Linux Mint 22.3 or a close Ubuntu Noble derivative
- Stock Linux kernel `7.1.x` already installed and selected at boot
- PipeWire and WirePlumber enabled for the user session
- `alsa-ucm-conf` installed
- `dkms` recommended but optional

## Prerequisites

Before running the installer, confirm the following:

1. You are logged into your normal desktop session, not a text console.
2. The machine is already running kernel `7.1.x`.
3. The internal AMD SoundWire audio card is visible to ALSA.
4. You can use `sudo` on the machine.
5. Basic audio packages are installed.

Check that with:

```bash
uname -r
aplay -l
pactl list cards short
sudo -v
dpkg -l | grep -E 'alsa-ucm-conf|pipewire|wireplumber|dkms'
```

Expected baseline:

1. `uname -r` shows a `7.1.x` kernel.
2. `aplay -l` shows `amd-soundwire` as a playback-capable card.
3. `pactl list cards short` shows `alsa_card.pci-0000_c4_00.5-platform-amd_sdw`.
4. `sudo -v` succeeds.
5. `alsa-ucm-conf`, PipeWire, and WirePlumber are installed.

## Install

From inside this `mint` folder, run:

```bash
bash install.sh
```

Important:

1. Do not run the whole script with `sudo`.
2. The script will ask for `sudo` only when it needs to write system files.
3. Run it from a graphical user session so it can restart your own PipeWire and WirePlumber services.

## What the installer does

The installer performs these steps:

1. Checks that the running kernel is `7.1+`.
2. Checks whether the patched `snd_soc_tas2783_sdw` module is already loaded from `/updates/` or `/updates/dkms/`.
3. If needed, installs the patched module using DKMS or a one-kernel fallback build.
4. Installs the Mint-compatible UCM files into `/usr/share/alsa/ucm2/`.
5. Installs `/lib/systemd/system-sleep/50-px13-soundwire`.
6. Validates that `alsaucm -c1 list _devices/HiFi` contains `Speaker`.
7. Restarts PipeWire and WirePlumber.
8. Switches the AMD SoundWire card to the `HiFi` profile.
9. Sets TAS2783 amp 1 to `Left` and amp 2 to `Right`.
10. Saves ALSA state.

## Verify after install

Run these commands:

```bash
modinfo -k $(uname -r) snd_soc_tas2783_sdw -F filename
amixer -D hw:1 cget name='tas2783-1 Channel Playback'
amixer -D hw:1 cget name='tas2783-2 Channel Playback'
alsaucm -c1 list _devices/HiFi
pactl list cards | grep 'Active Profile'
speaker-test -D pulse -c2 -l1 -t wav
```

Expected results:

1. `modinfo` points to a path under `/lib/modules/.../updates/` or `/lib/modules/.../updates/dkms/`.
2. `tas2783-1 Channel Playback` reports `Left`.
3. `tas2783-2 Channel Playback` reports `Right`.
4. `alsaucm` lists `Speaker` under `HiFi`.
5. `Active Profile` is `HiFi` for `alsa_card.pci-0000_c4_00.5-platform-amd_sdw`.
6. `speaker-test` announces `Front Left` on the left speaker and `Front Right` on the right speaker.

## Troubleshooting

### No `Speaker` device appears

Run:

```bash
alsaucm -c1 list _devices/HiFi
```

If `Speaker` is missing, check that this file exists:

```bash
/usr/share/alsa/ucm2/conf.d/amd-soundwire/ASUSTeKCOMPUTERINC.-ProArtPX13HN7306EAC-1.0-HN7306EAC.conf
```

That file is the Mint-specific part of the fix.

### `amd-soundwire` is not visible

If `aplay -l` does not show `amd-soundwire`, or `pactl list cards short` does not show `alsa_card.pci-0000_c4_00.5-platform-amd_sdw`, check the stack from the bottom up.

First confirm the ACP audio coprocessor exists on PCI:

```bash
lspci -nn | grep -i 'audio\|multimedia'
```

You should see the AMD ACP device at `c4:00.5`.

Then check whether the SoundWire-related modules are loaded:

```bash
lsmod | grep -E 'snd.*(acp|sdw|soundwire|tas2783)|soundwire'
```

On a working system you should see modules such as:

```text
snd_pci_ps
snd_acp_sdw_legacy_mach
soundwire_amd
snd_soc_tas2783_sdw
```

If they are missing, load them manually:

```bash
sudo modprobe snd_pci_ps
sudo modprobe snd_acp_sdw_legacy_mach
sudo modprobe snd_soc_tas2783_sdw
```

Then check again:

```bash
aplay -l
pactl list cards short
```

If the modules load but the card still does not appear, inspect kernel messages:

```bash
journalctl -k -b | grep -Ei 'snd_pci_ps|soundwire|amd_sdw|tas2783|acp'
```

If the AMD SoundWire controller is wedged, try rebinding the PCI device:

```bash
echo 0000:c4:00.5 | sudo tee /sys/bus/pci/drivers/snd_pci_ps/unbind
echo 0000:c4:00.5 | sudo tee /sys/bus/pci/drivers/snd_pci_ps/bind
```

Then restart user audio services:

```bash
systemctl --user restart wireplumber pipewire pipewire-pulse
pactl list cards short
```

If `aplay -l` still does not show `amd-soundwire` after that, the issue is below the Mint UCM layer. In that case, verify that you really are on the intended `7.1.x` kernel and reboot once before continuing. This Mint package only fixes the PX13 TAS2783/UCM path after the AMD SoundWire card is present.

### Only one speaker works or stereo collapses to the center

Run:

```bash
modinfo -k $(uname -r) snd_soc_tas2783_sdw -F filename
amixer -D hw:1 controls | grep 'Channel Playback'
```

If the module is not loaded from an `updates` path or the `Channel Playback` controls do not exist, the stock driver is still active.

### Suspend breaks the speakers

Run the hook manually:

```bash
sudo /lib/systemd/system-sleep/50-px13-soundwire post suspend
```

Then switch back to `HiFi` if needed:

```bash
pactl set-card-profile alsa_card.pci-0000_c4_00.5-platform-amd_sdw HiFi
```

### Left and right are swapped

Edit:

```bash
/usr/share/alsa/ucm2/sof-soundwire/tas2783.conf
```

Swap the two channel assignments, then restart audio:

```bash
systemctl --user restart pipewire wireplumber
```

### The installer says the kernel is too old

This package expects stock kernel `7.1` or newer because earlier kernels need the older out-of-tree patch set instead of this TAS2783 upstream-based path.

## Uninstall

If you need to back the fix out:

1. Remove `/usr/share/alsa/ucm2/conf.d/amd-soundwire/ASUSTeKCOMPUTERINC.-ProArtPX13HN7306EAC-1.0-HN7306EAC.conf`
2. Remove `/usr/share/alsa/ucm2/sof-soundwire/tas2783.conf`
3. Remove `/usr/share/alsa/ucm2/codecs/tas2783/init.conf`
4. Remove `/lib/systemd/system-sleep/50-px13-soundwire`
5. Remove the DKMS package or the manually installed module from `/lib/modules/$(uname -r)/updates/`
6. Run `sudo depmod -a $(uname -r)` if you removed a kernel module file manually
7. Restart PipeWire or reboot

## Notes for maintainers

This Mint package intentionally keeps the UCM file in `Syntax 6` form and uses a full PX13-specific `amd-soundwire` card config instead of the newer upstream overlay mechanism. That is the key Mint compatibility difference.