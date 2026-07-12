# ASUS ProArt PX13 Audio — Technical Deep Dive

**Status date**: 2026-07-11  
**Target**: ASUS ProArt PX13 (HN7306EA/EAC) with AMD Strix Halo + ACP 7.0 SoundWire controller

This document explains the root causes, evidence, and fix strategies for the audio problems on this laptop. It is reference material for understanding what's fixed in the kernel, what still needs patches, and what this repo's workarounds accomplish.

---

## The Hardware

- **Audio controller**: AMD ACP 7.0 (PCI `0000:c4:00.5`)
- **SoundWire peripherals**:
  - RT721 headset codec (PCM `hw:1,0` playback + `hw:1,1` mic via 3.5 mm jack)
  - TI TAS2783 × 2 (smart amps, built-in speakers, PCM `hw:1,2`, SoundWire addresses `sdw:0:1:0102:0000:01:8` and `:b`)
  - ACP DMIC array (PCM `hw:1,4`)
- **Firmware**: TAS2783 calibration blobs (per-model tuning, 40 KB each)
- **HDMI audio**: Separate HD-Audio device (works out of the box)

---

## Problem 1: Missing Firmware Blobs

**Symptom**: TAS2783 amps enumerate but refuse to produce sound.

**Root cause**: Linux has no calibration firmware for these amps. ASUS ships them only in Windows drivers (per-model tuning, measured at factory). Without the blob, the DSP doesn't initialize and audio fails silently.

**Status in kernels**:
- **Linux-firmware >= 20260519** (2026-05-19): TAS2783 blobs upstreamed as `ti/audio/tas2783/1714-1-0x8.bin` / `-0xB.bin` (TI-signed)
- **Distros**: Ubuntu 26.04 ships `20260319` (predates the upload) — manual install needed

**Fix**: Extract blobs from ASUS Windows driver, install to `/lib/firmware/`, provide symlinks for bare filenames (driver requests `1714-1-8.bin`, not the `0x` prefix).

---

## Problem 2: Mono from Both Amps (7.1+ only)

**Symptom**: One speaker plays all audio; which one changes per boot.

**Root cause**: The TI driver initializes both amp DSPs with the same cluster index (`0x01`) via `tas2783_init_seq`. The ASUS ACPI tables carry no SDCA/DisCo function data (reports `"function type only supported as DisCo constant"`), so the driver can't auto-assign channels. Result: mono from one random speaker.

**Status**:
- **7.0.x driver**: Stock driver does real stereo — issue doesn't exist
- **7.1+ driver**: New TI driver replaces nealstar's series; mono bug introduced and persists in 7.2-rc1

**Fix**: Add a `Channel Playback` control (nealstar's original patch, upstreamed for Arch/CachyOS, rebased here for DKMS). Sets each amp's DSP cluster index per-channel:
- Amp 1: Left (cluster `0x00`)
- Amp 2: Right (cluster `0x01` or `0x04` depending on amp)

Control only fires if loaded into the driver; guarded in UCM with `ControlExists` for backwards compatibility.

**Upstream needed**: Kernel patch — either the control directly or an ACPI quirk mapping `unique_id` to channel.

---

## Problem 3: Suspend/Resume Audio Dead

**Symptom**: After s2idle, speakers stay silent. Only fix: reboot.

**Root cause**: AMD SoundWire controller (`snd_pci_ps` / `amd_sdw_manager`) doesn't power back up cleanly. On wake:
- Card reappears (enumerated by BIOS)
- But driver can't re-attach peripherals (they stay `UNATTACHED`)
- Log: `AMD-Vi IO_PAGE_FAULT (address=0xff…fc)` repeating every bind attempt

**Why driver rebind (unbind + bind) doesn't work**: Tested on this machine, 3+ cycles — peripherals never re-attach, card becomes unusable.

**Why PCI remove+rescan works**: Forces full re-initialization of the hardware stack:
1. Removes the PCI device entirely from the kernel's view
2. Waits 3 s for PM to settle
3. Rescans the PCI bus
4. BIOS re-enumerates the device fresh
5. Driver probe runs from scratch → peripherals re-attach, firmware downloads succeed

Verified working repeatedly on kernel 7.0.0-27 (Ubuntu 26.04).

**Fix in this repo**: systemd-sleep hook that runs post-resume with PCI reset + full device restart + PipeWire refresh.

**Upstream needed**: Two parts (neither merged as of 2026-07-09):
1. AMD's slave re-enumeration patch ([linux-sound thread](https://lore.kernel.org/all/1ec22d6a-043b-4e10-956a-866d8d431011@kernel.org/)) — carried by CachyOS
2. tas2783 `regcache_sync` bug fix — under investigation

---

## Problem 4: Missing Speaker Device in HiFi Profile

**Symptom**: "Dummy Output" / no Speaker sink; only Pro-Audio profile works (cryptic device names).

**Root cause**: Machine driver doesn't tag `spk:tas2783` in card components. UCM looks for that tag to select the speaker codec config. Without it, HiFi profile activates but has no Speaker device.

**Fix**: Override the card's UCM config at a machine-specific path (`conf.d/amd-soundwire/<longname>.conf`) to define `SpeakerCodec1 = tas2783`. This path is unowned by any package → survives updates. Also provide codec configs (`tas2783.conf`, `acp-dmic.conf`) that define the Speaker and Mic devices and set channel indices (guarded by `ControlExists` for forward compat).

**Upstream needed**: Kernel patch to tag the components correctly.

---

## Problem 5: The FFFF-1-*.bin Bug

**Symptom**: During a re-probe (suspend recovery or Level 1 rebind), driver requests `FFFF-1-8.bin` instead of `1714-1-8.bin`, fails silently with `-2`, amps stay "error playback without fw download".

**Root cause**: `tas_generate_fw_name()` reads the parent PCI device's subsystem ID live on every probe. If config space isn't restored yet (window between PCI add and full probe), the read returns `0xFFFF`. Driver requests that name and fails.

**Fix**: Symlink `FFFF-1-8.bin` and `FFFF-1-B.bin` to the real blobs. If the wrong filename is requested, the alias resolves and keeps the probe alive.

**Upstream needed**: Cache the subsystem ID at first probe instead of re-reading it.

---

## What's Fixed Where

| Issue | 7.0.x | 7.1 | 7.2-rc1 | This Repo |
|-------|-------|-----|---------|-----------|
| Firmware blobs | — | — | — | ✓ Install |
| Cold-boot FW timeout race (`-110`) | Broken | Fixed | Fixed | ✓ Level 1 (7.0) |
| Mono from both amps | Works | **Broken** | **Broken** | ✓ DKMS Channel Playback |
| FFFF wrong-filename bug | Yes | Yes | Yes | ✓ Symlink aliases |
| Speaker device in HiFi | No | No | No | ✓ UCM override |
| Suspend/resume | Broken | Broken | Broken* | ✓ PCI reset hook |

*7.2-rc1 has partial AMD fix (slave re-enumeration); tas2783 regcache_sync bug remains.

---

## Verification Checklist

After install, check:

```bash
# 1. Firmware present?
ls -l /lib/firmware/1714-1-*.bin /lib/firmware/ti/audio/tas2783/

# 2. Module loaded (7.1+ only)?
modinfo -k $(uname -r) snd_soc_tas2783_sdw | grep -E 'filename|version'
# Must show: /lib/modules/.../updates/... (DKMS or manual build)

# 3. SoundWire peripherals attached?
cat /sys/bus/soundwire/devices/sdw:0:1:*/status
# All should be: Attached

# 4. Channel Playback controls present and set?
amixer -D hw:1 cget name='tas2783-1 Channel Playback'
amixer -D hw:1 cget name='tas2783-2 Channel Playback'
# Should show: values=1 (Left), values=2 (Right)

# 5. Speaker device in HiFi profile?
pactl list cards | grep -A5 'Active Profile'
# Should show: HiFi (with "sinks: 2")

# 6. Stereo works?
speaker-test -D pulse -c2 -l1 -t wav
# Voice L/R should come from correct side
```

---

## Recalibration for Other Laptop Variants

The repo pins several machine-specific values:

| Value | Scope | Change Trigger | Derivation |
|-------|-------|---|---|
| PCI address `0x00:c4:00.5` | Service/script | BIOS reorder, new hardware | `lspci -nn \| grep 'Audio Coprocessor'` |
| SoundWire addresses `sdw:0:1:0102:0000:01:8` / `:b` | Service/script | Chip replacement | `ls /sys/bus/soundwire/devices/` |
| Subsystem ID `1714` (firmware prefix) | Firmware naming | Different model | `lspci -s <acp-pci> -v \| grep Subsystem` |
| Card longname `ASUSTeKCOMPUTERINC.-ProArtPX13HN7306EAC-1.0-HN7306EAC` | UCM override path | BIOS DMI update | `awk '/amd-soundwire/{getline; gsub(/ /,""); print}' /proc/asound/cards` |
| PCM device numbers `hw:X,2` (speaker) / `hw:X,4` (DMIC) | UCM configs | Kernel driver reorder | `aplay -l` / `arecord -l` |

For different laptop SKUs: extract values from a running system, search the scripts/configs for hardcoded values, update every occurrence.

---

## Credits & Timeline

- **Hasun Park** (2025): PX13 machine-driver quirks upstreamed to 7.0
- **nealstar** (pre-7.1): 16-patch series with Channel Playback control
- **brainchillz** (2026-06): PCI-reset resume recovery + UCM analysis
- **barslmn, junjzhang** (2026-07): FFFF bug identification
- **AlexanderBartash** (2026-07-11): Comprehensive testing on stock 7.0, documented working resume recovery + provided this technical deep-dive

## Community Tracking

All ongoing work tracked in [CachyOS/linux-cachyos#737](https://github.com/CachyOS/linux-cachyos/issues/737) (107+ comments, all major findings reviewed).
