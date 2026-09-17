# Armbian AML-S9xx AIC8800 Image Customizer

This project modifies the official, prebuilt Armbian Ubuntu 26.04 XFCE image.
It does **not** clone or rebuild the Armbian build framework.

The resulting image includes:

- the `shenmintao/aic8800d80` main branch installed through DKMS;
- its firmware, udev rules, and Pandora `1111:1111` to `a69c:8d80` switch;
- a systemd/udev fallback that retries the upstream F3/F2 sequence;
- BlueZ and PipeWire/WirePlumber native HFP headset microphone support;
- `aic8800-audio-diagnose` for post-flash Bluetooth and microphone checks.

The official boot partition, bootloader, kernel, DTBs, and initramfs are kept
unchanged. The driver modules load from the root filesystem after it is mounted.

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
