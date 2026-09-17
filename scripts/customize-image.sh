#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 4 ]]; then
    echo "Usage: customize-image.sh IMAGE DRIVER_DIR OVERLAY_DIR RESULT_ENV" >&2
    exit 2
fi

IMAGE_PATH="$1"
DRIVER_DIR="$2"
OVERLAY_DIR="$3"
RESULT_ENV="$4"
MOUNT_BASE="$(mktemp -d /tmp/armbian-aic.XXXXXX)"
ROOT_MOUNT="${MOUNT_BASE}/root"
PROBE_MOUNT="${MOUNT_BASE}/probe"
LOOP_DEVICE=""
ROOT_DEVICE=""
BOOT_DEVICE=""
ROOT_MOUNTED=false
BOOT_MOUNTED=false
BOOT_PARTITION_SHA_BEFORE=""
BOOT_PARTITION_SHA_AFTER=""
BOOT_FILES_SHA_BEFORE="${MOUNT_BASE}/boot-files.before.sha256"
BOOT_FILES_SHA_AFTER="${MOUNT_BASE}/boot-files.after.sha256"
UBOOT_EXT_SHA256=""
RESOLV_REPLACED=false
RESOLV_BACKUP="${MOUNT_BASE}/resolv.conf.original"

mkdir -p "$ROOT_MOUNT" "$PROBE_MOUNT"

cleanup() {
    set +e
    if [[ "$RESOLV_REPLACED" == true ]]; then
        rm -f "${ROOT_MOUNT}/etc/resolv.conf"
        cp -a "$RESOLV_BACKUP" "${ROOT_MOUNT}/etc/resolv.conf"
    fi
    for bind_path in run sys proc dev/pts dev; do
        mountpoint -q "${ROOT_MOUNT}/${bind_path}" && umount -l "${ROOT_MOUNT}/${bind_path}"
    done
    [[ "$BOOT_MOUNTED" == true ]] && umount "${ROOT_MOUNT}/boot"
    [[ "$ROOT_MOUNTED" == true ]] && umount "$ROOT_MOUNT"
    mountpoint -q "$PROBE_MOUNT" && umount "$PROBE_MOUNT"
    [[ -n "$LOOP_DEVICE" ]] && losetup -d "$LOOP_DEVICE"
    rm -rf "$MOUNT_BASE"
}
trap cleanup EXIT

LOOP_DEVICE="$(losetup --find --show --partscan "$IMAGE_PATH")"
udevadm settle

# Docker Desktop exposes the kernel partition objects through sysfs, but its
# minimal /dev does not run a udev daemon to create loopXpN block nodes.
create_partition_nodes() {
    local loop_name sys_partition partition_name partition_major partition_minor
    loop_name="$(basename "$LOOP_DEVICE")"
    for sys_partition in /sys/class/block/"${loop_name}"p*; do
        [[ -e "$sys_partition/dev" ]] || continue
        partition_name="$(basename "$sys_partition")"
        IFS=: read -r partition_major partition_minor < "$sys_partition/dev"
        [[ -b "/dev/${partition_name}" ]] || mknod "/dev/${partition_name}" b "$partition_major" "$partition_minor"
    done
}
create_partition_nodes

mapfile -t PARTITIONS < <(lsblk --list --noheadings --paths --output NAME "$LOOP_DEVICE" | tail -n +2)
for partition in "${PARTITIONS[@]}"; do
    if mount -o ro "$partition" "$PROBE_MOUNT" 2>/dev/null; then
        if [[ -f "${PROBE_MOUNT}/etc/os-release" ]]; then
            ROOT_DEVICE="$partition"
        elif [[ -d "${PROBE_MOUNT}/extlinux" || -f "${PROBE_MOUNT}/armbianEnv.txt" || -f "${PROBE_MOUNT}/boot.ini" ]]; then
            BOOT_DEVICE="$partition"
        fi
        umount "$PROBE_MOUNT"
    fi
done

[[ -n "$ROOT_DEVICE" ]] || { echo "Could not identify the Armbian root partition" >&2; exit 1; }
[[ -n "$BOOT_DEVICE" ]] || { echo "Could not identify the Armbian boot partition" >&2; exit 1; }

mount "$ROOT_DEVICE" "$ROOT_MOUNT"
ROOT_MOUNTED=true
available_bytes="$(df --output=avail --block-size=1 "$ROOT_MOUNT" | tail -1 | tr -d ' ')"
# The current official desktop image has enough room for the retained DKMS
# toolchain. Avoid changing its MBR geometry unless space is genuinely tight;
# some vendor Amlogic boot chains are sensitive to partition-table changes.
required_bytes=$((512 * 1024 * 1024))
if ((available_bytes < required_bytes)); then
    deficit_bytes=$((required_bytes - available_bytes + 256 * 1024 * 1024))
    add_mib=$(((deficit_bytes + 1024 * 1024 - 1) / 1024 / 1024))
    root_partition_number="${ROOT_DEVICE#${LOOP_DEVICE}p}"
    [[ "$root_partition_number" =~ ^[0-9]+$ ]] || {
        echo "Cannot determine root partition number from $ROOT_DEVICE" >&2
        exit 1
    }
    echo "Growing the image by ${add_mib} MiB to provide driver build space..."
    umount "$ROOT_MOUNT"
    ROOT_MOUNTED=false
    boot_partition_number=""
    if [[ -n "$BOOT_DEVICE" ]]; then
        boot_partition_number="${BOOT_DEVICE#${LOOP_DEVICE}p}"
    fi
    truncate -s "+${add_mib}M" "$IMAGE_PATH"
    losetup --set-capacity "$LOOP_DEVICE"
    growpart "$LOOP_DEVICE" "$root_partition_number"
    old_loop_name="$(basename "$LOOP_DEVICE")"
    losetup -d "$LOOP_DEVICE"
    LOOP_DEVICE=""
    rm -f /dev/"${old_loop_name}"p*
    LOOP_DEVICE="$(losetup --find --show --partscan "$IMAGE_PATH")"
    udevadm settle
    create_partition_nodes
    ROOT_DEVICE="${LOOP_DEVICE}p${root_partition_number}"
    if [[ -n "$boot_partition_number" ]]; then
        BOOT_DEVICE="${LOOP_DEVICE}p${boot_partition_number}"
    fi
    e2fsck -f -y "$ROOT_DEVICE"
    resize2fs "$ROOT_DEVICE"
    mount "$ROOT_DEVICE" "$ROOT_MOUNT"
    ROOT_MOUNTED=true
fi

if [[ -n "$BOOT_DEVICE" ]]; then
    BOOT_PARTITION_SHA_BEFORE="$(sha256sum "$BOOT_DEVICE" | awk '{print $1}')"
    mount -o ro "$BOOT_DEVICE" "${ROOT_MOUNT}/boot"
    BOOT_MOUNTED=true
    (
        cd "${ROOT_MOUNT}/boot"
        find . -type f ! -name 'u-boot.ext' -print0 | sort -z | xargs -0 sha256sum
    ) > "$BOOT_FILES_SHA_BEFORE"
fi

# shellcheck disable=SC1091
source "${ROOT_MOUNT}/etc/os-release"
[[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 26.04 ]] || {
    echo "Expected Ubuntu 26.04, found ${ID:-unknown} ${VERSION_ID:-unknown}" >&2
    exit 1
}

chroot_exec() {
    chroot "$ROOT_MOUNT" /usr/bin/env \
        DEBIAN_FRONTEND=noninteractive \
        LC_ALL=C \
        LANG=C \
        bash -Eeuo pipefail -c "$1"
}

KERNEL_RELEASE="$(find "${ROOT_MOUNT}/lib/modules" -mindepth 1 -maxdepth 1 -type d -name '*current-meson64*' -printf '%f\n' | sort -V | tail -1)"
[[ -n "$KERNEL_RELEASE" ]] || { echo "No current-meson64 kernel found in image" >&2; exit 1; }

XFCE_VERSION_BEFORE="$(chroot "$ROOT_MOUNT" dpkg-query -W -f='${Version}' xfce4-session 2>/dev/null || true)"
[[ -n "$XFCE_VERSION_BEFORE" ]] || { echo "XFCE session package is missing from source image" >&2; exit 1; }

KERNEL_PACKAGE="$(chroot "$ROOT_MOUNT" dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\n' 'linux-image*meson64*' 2>/dev/null | awk '$1 == "ii " || $1 == "ii" {print $2; exit}')"
if [[ -z "$KERNEL_PACKAGE" ]]; then
    KERNEL_PACKAGE="linux-image-current-meson64"
fi
KERNEL_PACKAGE="${KERNEL_PACKAGE%%:*}"
KERNEL_PACKAGE_VERSION="$(chroot "$ROOT_MOUNT" dpkg-query -W -f='${Version}' "$KERNEL_PACKAGE")"
HEADER_PACKAGE="${KERNEL_PACKAGE/linux-image/linux-headers}"

for bind_path in dev dev/pts proc sys run; do
    mkdir -p "${ROOT_MOUNT}/${bind_path}"
done
mount --rbind /dev "${ROOT_MOUNT}/dev"
mount --make-rslave "${ROOT_MOUNT}/dev"
mount -t proc proc "${ROOT_MOUNT}/proc"
mount --rbind /sys "${ROOT_MOUNT}/sys"
mount --make-rslave "${ROOT_MOUNT}/sys"
mount --rbind /run "${ROOT_MOUNT}/run"
mount --make-rslave "${ROOT_MOUNT}/run"

cp -a "${ROOT_MOUNT}/etc/resolv.conf" "$RESOLV_BACKUP"
rm -f "${ROOT_MOUNT}/etc/resolv.conf"
cp /etc/resolv.conf "${ROOT_MOUNT}/etc/resolv.conf"
RESOLV_REPLACED=true

policy_path="${ROOT_MOUNT}/usr/sbin/policy-rc.d"
policy_backup=""
if [[ -e "$policy_path" ]]; then
    policy_backup="${policy_path}.aic-image-backup"
    mv "$policy_path" "$policy_backup"
fi
printf '#!/bin/sh\nexit 101\n' > "$policy_path"
chmod 0755 "$policy_path"

restore_policy() {
    rm -f "$policy_path"
    if [[ -n "$policy_backup" ]]; then
        mv "$policy_backup" "$policy_path"
    fi
}
trap 'restore_policy; cleanup' EXIT

echo "Installing exact kernel headers and runtime dependencies..."
chroot_exec "apt-get update"
HEADER_SOURCE="apt"
HEADER_INSTALL_ARGUMENT="${HEADER_PACKAGE}=${KERNEL_PACKAGE_VERSION}"
if ! chroot_exec "apt-cache show '${HEADER_INSTALL_ARGUMENT}' 2>/dev/null | grep -Fqx 'Version: ${KERNEL_PACKAGE_VERSION}'"; then
    KERNEL_ORIGINAL_HASH="$(chroot "$ROOT_MOUNT" dpkg-query -W -f='${Armbian-Original-Hash}' "$KERNEL_PACKAGE")"
    KERNEL_VERSION_NUMBER="${KERNEL_RELEASE%%-current-meson64}"
    [[ "$KERNEL_ORIGINAL_HASH" == "${KERNEL_VERSION_NUMBER}-"* ]] || {
        echo "Kernel package does not contain usable Armbian-Original-Hash metadata" >&2
        exit 1
    }
    OCI_REPOSITORY="armbian/os/kernel-meson64-current"
    OCI_TAG="$KERNEL_ORIGINAL_HASH"
    OCI_TOKEN="$(curl --fail --location --silent --show-error \
        'https://ghcr.io/token?scope=repository%3Aarmbian%2Fos%2Fkernel-meson64-current%3Apull' \
        | python3 -c 'import json, sys; print(json.load(sys.stdin)["token"])')"
    OCI_MANIFEST="${MOUNT_BASE}/kernel-manifest.json"
    curl --fail --location --silent --show-error \
        --header "Authorization: Bearer ${OCI_TOKEN}" \
        --header 'Accept: application/vnd.oci.image.manifest.v1+json' \
        "https://ghcr.io/v2/${OCI_REPOSITORY}/manifests/${OCI_TAG}" \
        -o "$OCI_MANIFEST"
    OCI_LAYER_DIGEST="$(python3 -c \
        'import json, sys; data=json.load(open(sys.argv[1])); assert data.get("artifactType") == "application/vnd.unknown.artifact.v1"; layers=data["layers"]; assert len(layers) == 1; print(layers[0]["digest"])' \
        "$OCI_MANIFEST")"
    [[ "$OCI_LAYER_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]
    OCI_ARTIFACT="${MOUNT_BASE}/kernel-artifact.tar"
    curl --fail --location --silent --show-error \
        --header "Authorization: Bearer ${OCI_TOKEN}" \
        "https://ghcr.io/v2/${OCI_REPOSITORY}/blobs/${OCI_LAYER_DIGEST}" \
        -o "$OCI_ARTIFACT"
    printf '%s  %s\n' "${OCI_LAYER_DIGEST#sha256:}" "$OCI_ARTIFACT" | sha256sum --check --status

    HEADER_FILENAME="${HEADER_PACKAGE}_${KERNEL_ORIGINAL_HASH}_arm64.deb"
    HEADER_ARTIFACT_PATH="global/${HEADER_FILENAME}"
    tar -tf "$OCI_ARTIFACT" | grep -Fqx "$HEADER_ARTIFACT_PATH"
    tar -xf "$OCI_ARTIFACT" -C "${ROOT_MOUNT}/tmp" "$HEADER_ARTIFACT_PATH"
    mv "${ROOT_MOUNT}/tmp/${HEADER_ARTIFACT_PATH}" "${ROOT_MOUNT}/tmp/${HEADER_FILENAME}"
    rmdir "${ROOT_MOUNT}/tmp/global"
    HEADER_SOURCE="oci://ghcr.io/${OCI_REPOSITORY}:${OCI_TAG}@${OCI_LAYER_DIGEST}#${HEADER_ARTIFACT_PATH}"
    echo "The rolling repository no longer lists the matching headers; extracted the immutable official OCI artifact ${HEADER_SOURCE}"
    [[ "$(dpkg-deb --field "${ROOT_MOUNT}/tmp/${HEADER_FILENAME}" Package)" == "$HEADER_PACKAGE" ]]
    [[ "$(dpkg-deb --field "${ROOT_MOUNT}/tmp/${HEADER_FILENAME}" Version)" == "$KERNEL_ORIGINAL_HASH" ]]
    [[ "$(dpkg-deb --field "${ROOT_MOUNT}/tmp/${HEADER_FILENAME}" Architecture)" == arm64 ]]
    HEADER_INSTALL_ARGUMENT="/tmp/${HEADER_FILENAME}"
fi
chroot_exec "apt-get install -y --no-install-recommends '${HEADER_INSTALL_ARGUMENT}' dkms build-essential mokutil eject usb-modeswitch bluez pipewire-audio pavucontrol python3"

chroot_exec "test -r '/lib/modules/${KERNEL_RELEASE}/build/Makefile'" || {
    echo "Kernel build tree is missing for ${KERNEL_RELEASE}" >&2
    exit 1
}

echo "Installing AIC firmware, rules, mode switch configuration, and DKMS source..."
find "${ROOT_MOUNT}/lib/firmware" -maxdepth 1 -type d -name 'aic8800*' -exec rm -rf -- {} +
for firmware_dir in "${DRIVER_DIR}"/fw/aic8800*; do
    [[ -d "$firmware_dir" ]] && cp -a "$firmware_dir" "${ROOT_MOUNT}/lib/firmware/"
done
install -D -m 0644 "${DRIVER_DIR}/aic.rules" "${ROOT_MOUNT}/usr/lib/udev/rules.d/aic.rules"
install -D -m 0644 "${DRIVER_DIR}/usb_modeswitch/1111_1111" "${ROOT_MOUNT}/etc/usb_modeswitch.d/1111:1111"

rm -rf "${ROOT_MOUNT}/usr/src/aic8800-1.0.0"
mkdir -p "${ROOT_MOUNT}/usr/src/aic8800-1.0.0"
cp -a "${DRIVER_DIR}/." "${ROOT_MOUNT}/usr/src/aic8800-1.0.0/"
rm -rf "${ROOT_MOUNT}/usr/src/aic8800-1.0.0/.git"

chroot_exec "dkms status -m aic8800 -v 1.0.0 >/dev/null 2>&1 && dkms remove -m aic8800 -v 1.0.0 --all || true"
chroot_exec "dkms add -m aic8800 -v 1.0.0"
chroot_exec "dkms build -m aic8800 -v 1.0.0 -k '${KERNEL_RELEASE}'"
chroot_exec "dkms install -m aic8800 -v 1.0.0 -k '${KERNEL_RELEASE}'"

cp -a "${OVERLAY_DIR}/." "$ROOT_MOUNT/"
chmod 0755 \
    "${ROOT_MOUNT}/usr/local/sbin/aic8800-pandora-switch" \
    "${ROOT_MOUNT}/usr/local/bin/aic8800-audio-diagnose"
chroot_exec "systemctl enable aic8800-pandora-fallback.service"
chroot_exec "depmod -a '${KERNEL_RELEASE}'"

echo "Verifying customized image..."
chroot_exec "dkms status -m aic8800 -v 1.0.0 -k '${KERNEL_RELEASE}' | grep -q installed"
for module_name in aic8800_fdrv aic_load_fw aic_zlp_quirk; do
    vermagic="$(chroot "$ROOT_MOUNT" modinfo -k "$KERNEL_RELEASE" -F vermagic "$module_name")"
    [[ "$vermagic" == "${KERNEL_RELEASE}"* ]] || {
        echo "Bad vermagic for ${module_name}: ${vermagic}" >&2
        exit 1
    }
done
find "${ROOT_MOUNT}/lib/modules/${KERNEL_RELEASE}" -type f -name 'btusb.ko*' -print -quit | grep -q .
find "${ROOT_MOUNT}/lib/firmware" -maxdepth 1 -type d -name 'aic8800*' -print -quit | grep -q .
grep -q '1111.*1111' "${ROOT_MOUNT}/usr/lib/udev/rules.d/aic.rules"
grep -Eq 'MessageContent="[0-9a-fA-F]*f3"' "${ROOT_MOUNT}/etc/usb_modeswitch.d/1111:1111"
grep -Eq 'MessageContent2="[0-9a-fA-F]*f2"' "${ROOT_MOUNT}/etc/usb_modeswitch.d/1111:1111"
grep -q 'bluetooth.autoswitch-to-headset-profile = true' "${ROOT_MOUNT}/etc/wireplumber/wireplumber.conf.d/60-aic8800-bluetooth.conf"
grep -Fqx 'blacklist aic8800_btusb' "${ROOT_MOUNT}/etc/modprobe.d/blacklist-aic8800-btusb.conf"
grep -Fqx 'install aic8800_btusb /bin/false' "${ROOT_MOUNT}/etc/modprobe.d/blacklist-aic8800-btusb.conf"
chroot_exec "dpkg-query -W bluez pipewire-audio libspa-0.2-bluetooth wireplumber >/dev/null"
if chroot_exec "dpkg-query -W -f='\${db:Status-Abbrev}' pulseaudio-module-bluetooth 2>/dev/null | grep -q '^ii'"; then
    echo "Competing PulseAudio Bluetooth module is installed" >&2
    exit 1
fi

XFCE_VERSION_AFTER="$(chroot "$ROOT_MOUNT" dpkg-query -W -f='${Version}' xfce4-session)"
[[ "$XFCE_VERSION_AFTER" == "$XFCE_VERSION_BEFORE" ]] || { echo "XFCE package changed unexpectedly" >&2; exit 1; }
KERNEL_VERSION_AFTER="$(chroot "$ROOT_MOUNT" dpkg-query -W -f='${Version}' "$KERNEL_PACKAGE")"
[[ "$KERNEL_VERSION_AFTER" == "$KERNEL_PACKAGE_VERSION" ]] || { echo "Kernel package changed unexpectedly" >&2; exit 1; }

HEADER_PACKAGE_VERSION="$(chroot "$ROOT_MOUNT" dpkg-query -W -f='${Version}' "$HEADER_PACKAGE")"
DKMS_PACKAGE_VERSION="$(chroot "$ROOT_MOUNT" dpkg-query -W -f='${Version}' dkms)"
BUILD_ESSENTIAL_VERSION="$(chroot "$ROOT_MOUNT" dpkg-query -W -f='${Version}' build-essential)"
USB_MODESWITCH_VERSION="$(chroot "$ROOT_MOUNT" dpkg-query -W -f='${Version}' usb-modeswitch)"
BLUEZ_VERSION="$(chroot "$ROOT_MOUNT" dpkg-query -W -f='${Version}' bluez)"
PIPEWIRE_AUDIO_VERSION="$(chroot "$ROOT_MOUNT" dpkg-query -W -f='${Version}' pipewire-audio)"
WIREPLUMBER_VERSION="$(chroot "$ROOT_MOUNT" dpkg-query -W -f='${Version}' wireplumber)"

chroot_exec "apt-get clean"
rm -rf "${ROOT_MOUNT}/var/lib/apt/lists"/* "${ROOT_MOUNT}/tmp"/* "${ROOT_MOUNT}/var/tmp"/*
restore_policy
trap cleanup EXIT

if [[ "$RESOLV_REPLACED" == true ]]; then
    rm -f "${ROOT_MOUNT}/etc/resolv.conf"
    cp -a "$RESOLV_BACKUP" "${ROOT_MOUNT}/etc/resolv.conf"
    RESOLV_REPLACED=false
fi
for bind_path in run sys proc dev/pts dev; do
    mountpoint -q "${ROOT_MOUNT}/${bind_path}" && umount -l "${ROOT_MOUNT}/${bind_path}"
done
if [[ "$BOOT_MOUNTED" == true ]]; then
    umount "${ROOT_MOUNT}/boot"
    BOOT_MOUNTED=false

    # The official boot partition is read-only throughout package and DKMS
    # installation. Remount it writable only for the targeted B860H SD fix.
    mount "$BOOT_DEVICE" "${ROOT_MOUNT}/boot"
    BOOT_MOUNTED=true
    bash /workspace/scripts/configure-b860h-sd-boot.sh "${ROOT_MOUNT}/boot"
    UBOOT_EXT_SHA256="$(sha256sum "${ROOT_MOUNT}/boot/u-boot.ext" | awk '{print $1}')"
    [[ "$UBOOT_EXT_SHA256" == "$(sha256sum "${ROOT_MOUNT}/boot/u-boot-s905x-s912" | awk '{print $1}')" ]]
    (
        cd "${ROOT_MOUNT}/boot"
        find . -type f ! -name 'u-boot.ext' -print0 | sort -z | xargs -0 sha256sum
    ) > "$BOOT_FILES_SHA_AFTER"
    cmp -s "$BOOT_FILES_SHA_BEFORE" "$BOOT_FILES_SHA_AFTER" || {
        echo "A boot file other than u-boot.ext changed during customization" >&2
        diff -u "$BOOT_FILES_SHA_BEFORE" "$BOOT_FILES_SHA_AFTER" || true
        exit 1
    }
    sync -f "${ROOT_MOUNT}/boot"
    umount "${ROOT_MOUNT}/boot"
    BOOT_MOUNTED=false
    BOOT_PARTITION_SHA_AFTER="$(sha256sum "$BOOT_DEVICE" | awk '{print $1}')"
fi

cat > "$RESULT_ENV" <<EOF
DISTRO_ID='${ID}'
DISTRO_VERSION='${VERSION_ID}'
KERNEL_RELEASE='${KERNEL_RELEASE}'
KERNEL_PACKAGE='${KERNEL_PACKAGE}'
KERNEL_PACKAGE_VERSION='${KERNEL_PACKAGE_VERSION}'
XFCE_SESSION_VERSION='${XFCE_VERSION_AFTER}'
HEADER_SOURCE='${HEADER_SOURCE}'
HEADER_PACKAGE_VERSION='${HEADER_PACKAGE_VERSION}'
DKMS_PACKAGE_VERSION='${DKMS_PACKAGE_VERSION}'
BUILD_ESSENTIAL_VERSION='${BUILD_ESSENTIAL_VERSION}'
USB_MODESWITCH_VERSION='${USB_MODESWITCH_VERSION}'
BLUEZ_VERSION='${BLUEZ_VERSION}'
PIPEWIRE_AUDIO_VERSION='${PIPEWIRE_AUDIO_VERSION}'
WIREPLUMBER_VERSION='${WIREPLUMBER_VERSION}'
UBOOT_EXT_SOURCE='u-boot-s905x-s912'
UBOOT_EXT_SHA256='${UBOOT_EXT_SHA256}'
BOOT_PARTITION_SHA_BEFORE='${BOOT_PARTITION_SHA_BEFORE}'
BOOT_PARTITION_SHA_AFTER='${BOOT_PARTITION_SHA_AFTER}'
EOF

umount "$ROOT_MOUNT"
ROOT_MOUNTED=false
e2fsck -f -y "$ROOT_DEVICE"

echo "Image verification completed successfully."
