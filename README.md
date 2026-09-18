# Armbian AML-S9xx AIC8800 Image Customizer

This project modifies official, prebuilt Armbian images. It does **not** clone
or rebuild the Armbian build framework. Two source profiles are supported:

- `xfce` (default): Ubuntu 26.04 Resolute XFCE with Bluetooth headset audio;
- `minimal`: Debian 13 Trixie server with BlueZ controller support and optional
  Bluetooth audio.

Every resulting image includes:

- the `shenmintao/aic8800d80` main branch installed through DKMS;
- its firmware, udev rules, and Pandora `1111:1111` to `a69c:8d80` switch;
- a systemd/udev fallback that retries the upstream F3/F2 sequence;
- BlueZ enabled for pairing, BLE, HID, and RFCOMM;
- the standard kernel `btusb` transport, with the legacy `aic8800_btusb`
  transport explicitly blocked;
- targeted UDisks rules that hide `BOOT_EMMC` and `ROOTFS_EMMC` from UDisks
  clients while leaving other removable storage visible;
- the B860H/S905X SD chainloader installed as `/u-boot.ext`;
- `aic8800-bluetooth-diagnose` for post-flash controller checks.
- a corrected Armbian first-login Wi-Fi path that safely writes Netplan,
  unblocks the adapter, and keeps a valid association even when the public-IP
  lookup service is unavailable.

The XFCE profile additionally includes PipeWire/WirePlumber native HFP,
`pavucontrol`, the XFCE PulseAudio panel plugin, multimedia keys, and the
configured right-side panel layout. The minimal profile includes that audio
stack only when `--bluetooth-audio` is selected and never installs XFCE or GUI
audio tools.

The image keeps the official kernel, DTBs, initramfs, disk geometry, and
partition table. The sole boot-file addition is an exact copy of the official
`u-boot-s905x-s912` binary named `u-boot.ext`. Every other boot file is hashed
before and after customization and must remain unchanged.

The first-login wizard still uses Armbian's original prompts. Only its Wi-Fi
connection block is patched: SSIDs and passphrases are JSON-escaped into valid
Netplan YAML, errors are no longer hidden, and success is based on the local
wireless association instead of access to `ipinfo.io`. A failed attempt restores
the previous Netplan file rather than removing unrelated network settings.

## Build

Requirements: Apple-silicon Docker Desktop, `curl`, `git`, `xz`, and at least
11 GiB free in the workspace filesystem.

```sh
./build.sh --check
./build.sh                                      # Ubuntu XFCE, audio enabled
./build.sh --variant minimal                    # Debian server, BlueZ only
./build.sh --variant minimal --bluetooth-audio  # Debian server with HFP audio
```

Use `--output-dir DIR` to select another artifact directory. Passing
`--bluetooth-audio` for XFCE is accepted but redundant because audio is always
enabled for that profile.

Artifacts are written to `dist/`: the compressed image, SHA256 file, and JSON
manifest. The rolling image alias and driver branch are resolved on every run,
while the exact input checksum, profile, packages, and driver commit are
recorded in the manifest.

## Bluetooth on the minimal profile

BlueZ-only is recommended for a headless server. It exposes the AIC controller
without running a per-user media graph and does not make the controller
discoverable, pairable, or trusted automatically. Pair devices explicitly:

```sh
bluetoothctl
power on
scan on
```

With `--bluetooth-audio`, PipeWire and WirePlumber use their standard per-user
services. Log in as the user that owns the audio session and verify them:

```sh
systemctl --user status pipewire.socket pipewire-pulse.socket wireplumber.service
aic8800-audio-diagnose
```

If that audio session must remain available after logout, enable linger for
the intended account:

```sh
sudo loginctl enable-linger "$USER"
```

## Diagnostics and microphone verification

Controller-only diagnostics are available on every profile:

```sh
aic8800-bluetooth-diagnose
```

For an audio-enabled image, pair and connect a headset as the intended audio
user, then run:

```sh
aic8800-audio-diagnose
aic8800-audio-diagnose --record 5 microphone-test.wav
```

Starting capture should make WirePlumber switch the headset from A2DP to native
HFP. The recording reports nonzero samples and fails if the PCM stream is
completely silent.
