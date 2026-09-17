# Armbian AML-S9xx AIC8800 Image Customizer

This project modifies the official, prebuilt Armbian Ubuntu 26.04 XFCE image.
It does **not** clone or rebuild the Armbian build framework.

The resulting image includes:

- the `shenmintao/aic8800d80` main branch installed through DKMS;
- its firmware, udev rules, and Pandora `1111:1111` to `a69c:8d80` switch;
- a systemd/udev fallback that retries the upstream F3/F2 sequence;
- BlueZ and PipeWire/WirePlumber native HFP headset microphone support;
- the XFCE PulseAudio panel plugin backed by `pipewire-pulse`, with volume and
  media-player multimedia keys explicitly enabled;
- a default XFCE right-side panel ordered as Clock, separator, Full Name
  Session Menu, separator, PulseAudio, Network/Bluetooth tray, separator, and
  Workspace Switcher when read from right to left;
- targeted UDisks rules that hide `BOOT_EMMC` and `ROOTFS_EMMC` from desktop
  icons and Thunar while leaving other removable storage visible;
- the standard kernel `btusb` transport, with the silent legacy
  `aic8800_btusb` transport explicitly blocked;
- the B860H/S905X SD chainloader installed as `/u-boot.ext`;
- `aic8800-audio-diagnose` for post-flash Bluetooth and microphone checks.

The image keeps the official kernel, DTBs, initramfs, disk geometry, and
partition table. The sole boot-file addition is an exact copy of the official
`u-boot-s905x-s912` binary named `u-boot.ext`, which the existing official
`s905_autoscript` already attempts to load from SD. Every other boot file is
hashed before and after customization and must remain unchanged.

## Build

Requirements: Apple-silicon Docker Desktop, `curl`, `git`, `xz`, and at least
11 GiB free in the workspace filesystem.

```sh
./build.sh --check
./build.sh
```

Artifacts are written to `dist/`: the compressed image, SHA256 file, and JSON
manifest. The rolling image alias and driver branch are resolved on every run,
while the exact input checksum and driver commit are recorded in the manifest.

## Post-flash microphone verification

Pair and connect a Bluetooth headset, log into XFCE, and run:

```sh
aic8800-audio-diagnose
aic8800-audio-diagnose --record 5 microphone-test.wav
```

Starting capture should make WirePlumber switch the headset from A2DP to native
HFP. The recording command reports the number of nonzero samples and fails if
the captured PCM stream is completely silent.
