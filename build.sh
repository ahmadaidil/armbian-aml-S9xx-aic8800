#!/usr/bin/env bash
set -Eeuo pipefail

readonly ARMBIAN_IMAGE_ALIAS="https://dl.armbian.com/aml-s9xx-box/Resolute_current_xfce"
readonly ARMBIAN_SHA_ALIAS="${ARMBIAN_IMAGE_ALIAS}.sha"
readonly AIC_REPOSITORY="https://github.com/shenmintao/aic8800d80.git"
readonly AIC_BRANCH="main"
readonly BUILDER_IMAGE="armbian-aic8800-image-customizer:local"
readonly REQUIRED_FREE_GIB=11

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${PROJECT_DIR}/dist"
CHECK_ONLY=false

usage() {
    cat <<'EOF'
Usage: ./build.sh [--check] [--output-dir DIR]

  --check           Validate local prerequisites and available disk space only.
  --output-dir DIR  Write the compressed image and metadata to DIR (default: dist).
EOF
}

while (($#)); do
    case "$1" in
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
    "$CONTAINER_RESULT_ENV"

# shellcheck disable=SC1090
source "${WORK_DIR}/customization.env"

output_stem="${INPUT_NAME%.img.xz}-aic8800"
OUTPUT_IMAGE="${OUTPUT_DIR}/${output_stem}.img.xz"
OUTPUT_SHA_FILE="${OUTPUT_IMAGE}.sha256"
OUTPUT_MANIFEST="${OUTPUT_DIR}/${output_stem}.manifest.json"

echo "Compressing customized image..."
xz --compress --threads=0 --check=crc64 --stdout "$RAW_IMAGE" > "${OUTPUT_IMAGE}.partial"
mv "${OUTPUT_IMAGE}.partial" "$OUTPUT_IMAGE"
OUTPUT_SHA="$(shasum -a 256 "$OUTPUT_IMAGE" | awk '{print $1}')"
printf '%s  %s\n' "$OUTPUT_SHA" "$(basename "$OUTPUT_IMAGE")" > "$OUTPUT_SHA_FILE"

cat > "$OUTPUT_MANIFEST" <<EOF
{
  "source": {
    "alias": "${ARMBIAN_IMAGE_ALIAS}",
    "filename": "${INPUT_NAME}",
    "sha256": "${INPUT_SHA}",
    "distribution": "${DISTRO_ID}",
    "version": "${DISTRO_VERSION}",
    "kernel": "${KERNEL_RELEASE}",
    "kernel_package": "${KERNEL_PACKAGE}",
    "kernel_package_version": "${KERNEL_PACKAGE_VERSION}",
    "xfce_session_version": "${XFCE_SESSION_VERSION}",
    "headers_source": "${HEADER_SOURCE}"
  },
  "packages": {
    "linux-headers-current-meson64": "${HEADER_PACKAGE_VERSION}",
    "dkms": "${DKMS_PACKAGE_VERSION}",
    "build-essential": "${BUILD_ESSENTIAL_VERSION}",
    "usb-modeswitch": "${USB_MODESWITCH_VERSION}",
    "bluez": "${BLUEZ_VERSION}",
    "pipewire-audio": "${PIPEWIRE_AUDIO_VERSION}",
    "wireplumber": "${WIREPLUMBER_VERSION}"
  },
  "driver": {
    "repository": "${AIC_REPOSITORY}",
    "branch": "${AIC_BRANCH}",
    "commit": "${AIC_COMMIT}",
    "dkms": "aic8800/1.0.0",
    "modules": ["aic8800_fdrv", "aic_load_fw", "aic_zlp_quirk"]
  },
  "bluetooth_audio": {
    "transport": "btusb",
    "legacy_aic8800_btusb_blocked": true,
    "session_manager": "wireplumber",
    "hfp_backend": "native",
    "automatic_headset_profile": true
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
