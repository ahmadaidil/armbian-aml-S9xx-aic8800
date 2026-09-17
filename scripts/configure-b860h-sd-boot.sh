#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: configure-b860h-sd-boot.sh BOOT_DIRECTORY" >&2
    exit 2
fi

BOOT_DIRECTORY="$1"
UBOOT_SOURCE="${BOOT_DIRECTORY}/u-boot-s905x-s912"
UBOOT_TARGET="${BOOT_DIRECTORY}/u-boot.ext"
EXTLINUX_CONFIG="${BOOT_DIRECTORY}/extlinux/extlinux.conf"
S905_AUTOSCRIPT="${BOOT_DIRECTORY}/s905_autoscript"

[[ -f "$UBOOT_SOURCE" ]] || {
    echo "The official u-boot-s905x-s912 binary is missing" >&2
    exit 1
}
[[ -f "$S905_AUTOSCRIPT" ]] || {
    echo "The official s905_autoscript is missing" >&2
    exit 1
}
[[ -f "$EXTLINUX_CONFIG" ]] || {
    echo "The official extlinux configuration is missing" >&2
    exit 1
}

# This compiled Armbian script is the vendor-U-Boot entry point. Do not add the
# old boot.ini from unrelated images: the official script already loads this
# exact filename from SD (mmc 0) and USB before transferring control to it.
grep -aFq 'fatload mmc 0 0x1000000 u-boot.ext' "$S905_AUTOSCRIPT" || {
    echo "s905_autoscript does not contain the expected SD u-boot.ext chainloader" >&2
    exit 1
}

# The B860H/S905X recipe uses p212. The current official AML-S9xx image already
# selects it, so validate rather than replacing the modern kernel/root options.
grep -Eiq '^[[:space:]]*fdt[[:space:]]+/dtb/amlogic/meson-gxl-s905x-p212\.dtb[[:space:]]*$' "$EXTLINUX_CONFIG" || {
    echo "extlinux.conf does not select meson-gxl-s905x-p212.dtb" >&2
    exit 1
}

install -m 0644 "$UBOOT_SOURCE" "$UBOOT_TARGET"
cmp -s "$UBOOT_SOURCE" "$UBOOT_TARGET" || {
    echo "u-boot.ext does not match u-boot-s905x-s912" >&2
    exit 1
}
