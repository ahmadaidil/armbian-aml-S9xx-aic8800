#!/usr/bin/env bash
set -Eeuo pipefail

readonly AIC_REPOSITORY="https://github.com/shenmintao/aic8800d80.git"
readonly AIC_BRANCH="main"
readonly BUILDER_IMAGE="armbian-aic8800-image-customizer:local"
readonly REQUIRED_FREE_GIB=11

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${PROJECT_DIR}/dist"
CHECK_ONLY=false
VARIANT="xfce"
BLUETOOTH_AUDIO_REQUESTED=false

usage() {
    cat <<'EOF'
Usage: ./build.sh [--variant xfce|minimal] [--bluetooth-audio] [--check] [--output-dir DIR]

  --variant VARIANT   Build xfce (default) or minimal.
  --bluetooth-audio   Add PipeWire/WirePlumber Bluetooth audio to minimal.
                      XFCE already includes Bluetooth audio.
  --check             Validate the selected profile, prerequisites, and disk space.
  --output-dir DIR    Write the compressed image and metadata to DIR (default: dist).
EOF
}

while (($#)); do
    case "$1" in
        --variant)
            [[ $# -ge 2 ]] || { echo "--variant requires xfce or minimal" >&2; exit 2; }
            VARIANT="$2"
            shift 2
            ;;
        --bluetooth-audio)
            BLUETOOTH_AUDIO_REQUESTED=true
            shift
            ;;
        --check)
            CHECK_ONLY=true
            shift
            ;;
        --output-dir)
            [[ $# -ge 2 ]] || { echo "--output-dir requires a directory" >&2; exit 2; }
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "$VARIANT" in
    xfce)
        ARMBIAN_IMAGE_ALIAS="https://dl.armbian.com/aml-s9xx-box/Resolute_current_xfce"
        EXPECTED_DISTRO_ID="ubuntu"
        EXPECTED_DISTRO_VERSION="26.04"
        BLUETOOTH_AUDIO=true
        if [[ "$BLUETOOTH_AUDIO_REQUESTED" == true ]]; then
            echo "Notice: --bluetooth-audio is already enabled by the XFCE profile."
        fi
        ;;
    minimal)
        ARMBIAN_IMAGE_ALIAS="https://dl.armbian.com/aml-s9xx-box/Trixie_current_minimal"
        EXPECTED_DISTRO_ID="debian"
        EXPECTED_DISTRO_VERSION="13"
        BLUETOOTH_AUDIO="$BLUETOOTH_AUDIO_REQUESTED"
        ;;
    *)
        echo "Invalid variant: $VARIANT (expected xfce or minimal)" >&2
        usage >&2
        exit 2
        ;;
esac
ARMBIAN_SHA_ALIAS="${ARMBIAN_IMAGE_ALIAS}.sha"

for command_name in curl docker git shasum tar xz; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "Missing required command: $command_name" >&2
        exit 1
    }
done

docker info >/dev/null 2>&1 || {
    echo "Docker is not running or is not accessible." >&2
    exit 1
}

available_kib="$(df -Pk "$PROJECT_DIR" | awk 'NR == 2 {print $4}')"
required_kib=$((REQUIRED_FREE_GIB * 1024 * 1024))
if ((available_kib < required_kib)); then
    printf 'At least %s GiB free is required; only %.1f GiB is available.\n' \
        "$REQUIRED_FREE_GIB" "$(awk -v kib="$available_kib" 'BEGIN {print kib / 1024 / 1024}')" >&2
    exit 1
fi

if [[ "$CHECK_ONLY" == true ]]; then
    printf 'Prerequisites OK; %.1f GiB is available.\n' \
        "$(awk -v kib="$available_kib" 'BEGIN {print kib / 1024 / 1024}')"
    printf 'Variant: %s\nBluetooth audio: %s\nImage alias: %s\nExpected distribution: %s %s\n' \
        "$VARIANT" "$BLUETOOTH_AUDIO" "$ARMBIAN_IMAGE_ALIAS" \
        "$EXPECTED_DISTRO_ID" "$EXPECTED_DISTRO_VERSION"
    exit 0
fi

mkdir -p "$OUTPUT_DIR" "${PROJECT_DIR}/.cache" "${PROJECT_DIR}/.work"
WORK_DIR="$(mktemp -d "${PROJECT_DIR}/.work/build.XXXXXX")"
INPUT_XZ=""
RAW_IMAGE=""

cleanup() {
    if [[ -n "$RAW_IMAGE" && -f "$RAW_IMAGE" ]]; then
        rm -f "$RAW_IMAGE"
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

download_image() {
    local attempt sha_line expected_sha expected_name candidate
    for attempt in 1 2 3; do
        echo "Resolving rolling Armbian image (attempt ${attempt}/3)..."
        curl --fail --location --silent --show-error "$ARMBIAN_SHA_ALIAS" -o "${WORK_DIR}/image.sha"
        sha_line="$(awk 'NF >= 2 && $1 ~ /^[[:xdigit:]]{64}$/ {print $1, $2; exit}' "${WORK_DIR}/image.sha")"
        [[ -n "$sha_line" ]] || { echo "Invalid Armbian SHA sidecar" >&2; return 1; }
        expected_sha="${sha_line%% *}"
        expected_name="${sha_line#* }"
        expected_name="${expected_name#\*}"
        [[ "$expected_name" != */* && "$expected_name" == *.img.xz ]] || {
            echo "Unsafe or unexpected image filename in SHA sidecar: $expected_name" >&2
            return 1
        }
        case "$VARIANT" in
            xfce)
                [[ "$expected_name" == *_resolute_current_*_xfce_desktop.img.xz ]] || {
                    echo "SHA sidecar does not describe a Resolute current XFCE image: $expected_name" >&2
                    return 1
                }
                ;;
            minimal)
                [[ "$expected_name" == *_trixie_current_*_minimal.img.xz ]] || {
                    echo "SHA sidecar does not describe a Trixie current minimal image: $expected_name" >&2
                    return 1
                }
                ;;
        esac
        candidate="${PROJECT_DIR}/.cache/${expected_name}"
        if [[ ! -f "$candidate" ]]; then
            curl --fail --location --show-error --progress-bar "$ARMBIAN_IMAGE_ALIAS" -o "${candidate}.partial"
            mv "${candidate}.partial" "$candidate"
        fi
        if printf '%s  %s\n' "$expected_sha" "$candidate" | shasum -a 256 -c -; then
            INPUT_XZ="$candidate"
            INPUT_SHA="$expected_sha"
            INPUT_NAME="$expected_name"
            return 0
        fi
        rm -f "$candidate"
        echo "The rolling alias moved or the download was corrupt; retrying." >&2
    done
    return 1
}

download_image

echo "Resolving AIC8800D80 main branch..."
AIC_COMMIT="$(git ls-remote "$AIC_REPOSITORY" "refs/heads/${AIC_BRANCH}" | awk 'NR == 1 {print $1}')"
[[ "$AIC_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "Could not resolve AIC driver commit" >&2; exit 1; }
git clone --quiet --filter=blob:none --no-checkout "$AIC_REPOSITORY" "${WORK_DIR}/aic8800d80"
git -C "${WORK_DIR}/aic8800d80" checkout --quiet --detach "$AIC_COMMIT"
rm -rf "${WORK_DIR}/aic8800d80/.git"

RAW_IMAGE="${WORK_DIR}/${INPUT_NAME%.xz}"
echo "Decompressing ${INPUT_NAME}..."
xz --decompress --keep --threads=0 --stdout "$INPUT_XZ" > "$RAW_IMAGE"

echo "Building the ARM64 customization environment..."
docker build --platform linux/arm64 --tag "$BUILDER_IMAGE" "$PROJECT_DIR"

echo "Customizing the downloaded image..."
CONTAINER_RAW_IMAGE="/workspace/${RAW_IMAGE#${PROJECT_DIR}/}"
CONTAINER_DRIVER_DIR="/workspace/${WORK_DIR#${PROJECT_DIR}/}/aic8800d80"
CONTAINER_RESULT_ENV="/workspace/${WORK_DIR#${PROJECT_DIR}/}/customization.env"
docker run --rm --privileged --platform linux/arm64 \
    --volume "${PROJECT_DIR}:/workspace" \
    "$BUILDER_IMAGE" \
    /workspace/scripts/customize-image.sh \
    "$CONTAINER_RAW_IMAGE" \
    "$CONTAINER_DRIVER_DIR" \
    /workspace/overlay \
    "$CONTAINER_RESULT_ENV" \
    "$VARIANT" \
    "$BLUETOOTH_AUDIO"

# shellcheck disable=SC1090
source "${WORK_DIR}/customization.env"

output_stem="${INPUT_NAME%.img.xz}-aic8800"
if [[ "$VARIANT" == minimal && "$BLUETOOTH_AUDIO" == true ]]; then
    output_stem+="-btaudio"
fi
OUTPUT_IMAGE="${OUTPUT_DIR}/${output_stem}.img.xz"
OUTPUT_SHA_FILE="${OUTPUT_IMAGE}.sha256"
OUTPUT_MANIFEST="${OUTPUT_DIR}/${output_stem}.manifest.json"

echo "Compressing customized image..."
xz --compress --threads=0 --check=crc64 --stdout "$RAW_IMAGE" > "${OUTPUT_IMAGE}.partial"
mv "${OUTPUT_IMAGE}.partial" "$OUTPUT_IMAGE"
OUTPUT_SHA="$(shasum -a 256 "$OUTPUT_IMAGE" | awk '{print $1}')"
printf '%s  %s\n' "$OUTPUT_SHA" "$(basename "$OUTPUT_IMAGE")" > "$OUTPUT_SHA_FILE"

json_nullable_string() {
    if [[ -n "$1" ]]; then
        printf '"%s"' "$1"
    else
        printf 'null'
    fi
}

XFCE_SESSION_JSON="$(json_nullable_string "$XFCE_SESSION_VERSION")"
PIPEWIRE_AUDIO_JSON="$(json_nullable_string "$PIPEWIRE_AUDIO_VERSION")"
LIBSPA_BLUETOOTH_JSON="$(json_nullable_string "$LIBSPA_BLUETOOTH_VERSION")"
WIREPLUMBER_JSON="$(json_nullable_string "$WIREPLUMBER_VERSION")"
PULSEAUDIO_UTILS_JSON="$(json_nullable_string "$PULSEAUDIO_UTILS_VERSION")"
PYTHON3_JSON="$(json_nullable_string "$PYTHON3_VERSION")"
PAVUCONTROL_JSON="$(json_nullable_string "$PAVUCONTROL_VERSION")"
XFCE_PULSEAUDIO_PLUGIN_JSON="$(json_nullable_string "$XFCE_PULSEAUDIO_PLUGIN_VERSION")"
if [[ "$BLUETOOTH_AUDIO" == true ]]; then
    AUDIO_SESSION_MANAGER_JSON='"wireplumber"'
    HFP_BACKEND_JSON='"native"'
else
    AUDIO_SESSION_MANAGER_JSON='null'
    HFP_BACKEND_JSON='null'
fi
if [[ "$VARIANT" == xfce ]]; then
    DESKTOP_ENABLED=true
    PANEL_ORDER_JSON='["clock", "separator", "actions-full-name", "separator", "pulseaudio", "network", "bluetooth", "separator", "workspace-switcher"]'
else
    DESKTOP_ENABLED=false
    PANEL_ORDER_JSON='null'
fi

cat > "$OUTPUT_MANIFEST" <<EOF
{
  "profile": {
    "variant": "${VARIANT}",
    "bluetooth_audio": ${BLUETOOTH_AUDIO}
  },
  "source": {
    "alias": "${ARMBIAN_IMAGE_ALIAS}",
    "filename": "${INPUT_NAME}",
    "sha256": "${INPUT_SHA}",
    "distribution": "${DISTRO_ID}",
    "version": "${DISTRO_VERSION}",
    "kernel": "${KERNEL_RELEASE}",
    "kernel_package": "${KERNEL_PACKAGE}",
    "kernel_package_version": "${KERNEL_PACKAGE_VERSION}",
    "xfce_session_version": ${XFCE_SESSION_JSON},
    "headers_source": "${HEADER_SOURCE}"
  },
  "packages": {
    "linux-headers-current-meson64": "${HEADER_PACKAGE_VERSION}",
    "dkms": "${DKMS_PACKAGE_VERSION}",
    "build-essential": "${BUILD_ESSENTIAL_VERSION}",
    "usb-modeswitch": "${USB_MODESWITCH_VERSION}",
    "usbutils": "${USBUTILS_VERSION}",
    "bluez": "${BLUEZ_VERSION}",
    "pipewire-audio": ${PIPEWIRE_AUDIO_JSON},
    "libspa-0.2-bluetooth": ${LIBSPA_BLUETOOTH_JSON},
    "wireplumber": ${WIREPLUMBER_JSON},
    "pulseaudio-utils": ${PULSEAUDIO_UTILS_JSON},
    "python3": ${PYTHON3_JSON},
    "pavucontrol": ${PAVUCONTROL_JSON},
    "xfce4-pulseaudio-plugin": ${XFCE_PULSEAUDIO_PLUGIN_JSON}
  },
  "driver": {
    "repository": "${AIC_REPOSITORY}",
    "branch": "${AIC_BRANCH}",
    "commit": "${AIC_COMMIT}",
    "dkms": "aic8800/1.0.0",
    "modules": ["aic8800_fdrv", "aic_load_fw", "aic_zlp_quirk"]
  },
  "first_login_wifi": {
    "netplan_configuration": "json-yaml",
    "association_check": "local-iw-link",
    "external_connectivity_required": false,
    "rfkill_unblock": true
  },
  "bluetooth_audio": {
    "enabled": ${BLUETOOTH_AUDIO},
    "transport": "btusb",
    "legacy_aic8800_btusb_blocked": true,
    "session_manager": ${AUDIO_SESSION_MANAGER_JSON},
    "hfp_backend": ${HFP_BACKEND_JSON},
    "automatic_headset_profile": ${BLUETOOTH_AUDIO}
  },
  "desktop": {
    "xfce": ${DESKTOP_ENABLED},
    "xfce_panel_plugin": ${DESKTOP_ENABLED},
    "xfce_multimedia_keys": ${DESKTOP_ENABLED},
    "xfce_panel_order_right_to_left": ${PANEL_ORDER_JSON},
    "hidden_volume_labels": ["BOOT_EMMC", "ROOTFS_EMMC"]
  },
  "boot": {
    "source_partition_sha256": "${BOOT_PARTITION_SHA_BEFORE}",
    "customized_partition_sha256": "${BOOT_PARTITION_SHA_AFTER}",
    "sd_chainloader": "u-boot.ext",
    "sd_chainloader_source": "${UBOOT_EXT_SOURCE}",
    "sd_chainloader_sha256": "${UBOOT_EXT_SHA256}",
    "dtb": "amlogic/meson-gxl-s905x-p212.dtb",
    "all_other_boot_files_preserved": true,
    "kernel_and_dtb_preserved": true,
    "initramfs_preserved": true
  },
  "output": {
    "filename": "$(basename "$OUTPUT_IMAGE")",
    "sha256": "${OUTPUT_SHA}"
  }
}
EOF

echo "Build complete:"
echo "  Image:    $OUTPUT_IMAGE"
echo "  SHA256:   $OUTPUT_SHA_FILE"
echo "  Manifest: $OUTPUT_MANIFEST"
