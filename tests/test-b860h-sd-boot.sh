#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURE_SCRIPT="${PROJECT_DIR}/scripts/configure-b860h-sd-boot.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

make_fixture() {
    rm -rf "${TEST_ROOT}/boot"
    mkdir -p "${TEST_ROOT}/boot/extlinux"
    printf 'official u-boot payload\n' > "${TEST_ROOT}/boot/u-boot-s905x-s912"
    printf 'fatload mmc 0 0x1000000 u-boot.ext\n' > "${TEST_ROOT}/boot/s905_autoscript"
    printf 'label Armbian\n  kernel /Image\n  initrd /uInitrd\n  fdt /dtb/amlogic/meson-gxl-s905x-p212.dtb\n' \
        > "${TEST_ROOT}/boot/extlinux/extlinux.conf"
}

echo "Test: install the official S905X/S912 chainloader"
make_fixture
bash "$CONFIGURE_SCRIPT" "${TEST_ROOT}/boot"
cmp -s "${TEST_ROOT}/boot/u-boot-s905x-s912" "${TEST_ROOT}/boot/u-boot.ext"

echo "Test: reject an unexpected DTB without rewriting extlinux"
make_fixture
sed -i.bak 's/meson-gxl-s905x-p212/meson-gxl-s905x-khadas-vim/' \
    "${TEST_ROOT}/boot/extlinux/extlinux.conf"
rm "${TEST_ROOT}/boot/extlinux/extlinux.conf.bak"
if bash "$CONFIGURE_SCRIPT" "${TEST_ROOT}/boot"; then
    echo "Expected an unexpected DTB to be rejected" >&2
    exit 1
fi
[[ ! -e "${TEST_ROOT}/boot/u-boot.ext" ]]

echo "Test: reject a boot script without the SD chainloader command"
make_fixture
printf 'echo no chainloader\n' > "${TEST_ROOT}/boot/s905_autoscript"
if bash "$CONFIGURE_SCRIPT" "${TEST_ROOT}/boot"; then
    echo "Expected the missing chainloader command to be rejected" >&2
    exit 1
fi
[[ ! -e "${TEST_ROOT}/boot/u-boot.ext" ]]

echo "B860H SD boot tests passed"
