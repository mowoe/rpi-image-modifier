#!/bin/bash

set -e

echo_green() {
    echo -e "\x1B[1m>>> \x1B[0m\x1B[32;1m$@\x1B[0m"
}

error() {
    echo -e "\x1B[31;1mERROR: $@\x1B[0m"
    exit 1
}

echo_green 'Starting rpi-image-modifier action'

# Check we're Linux and have the proper arguments
if [ "${RUNNER_OS}" != "Linux" ]; then
    error "${RUNNER_OS} not supported"
fi

if [ -z "${__ARG_SCRIPT_PATH}" -a -z "${__ARG_RUN}" ] || [ "${__ARG_SCRIPT_PATH}" -a "${__ARG_RUN}" ]; then
    echo_red 'You must specify either a script-path or run input, but not both.'
fi

if [ "${__ARG_ENV_VARS}" ] && echo "${__ARG_ENV_VARS}" | grep -vqE '^([a-zA-Z_][a-zA-Z_0-9]*,)*([a-zA-Z_][a-zA-Z_0-9]*)$'; then
    echo_red 'Argument env-vars was malformed, must be a comma-separated list of variables.'
fi

echo_green 'Installing dependencies'

sudo apt-get update -q

# qemu-user-static automatically installs aarch64/arm interpeters
sudo apt-get install -y -q --no-install-recommends \
    pwgen \
    qemu-user-static \
    systemd-container

if [ "${__ARG_SHRINK}" ]; then
    sudo wget -q -O /usr/local/bin/pishrink.sh https://raw.githubusercontent.com/Drewsif/PiShrink/master/pishrink.sh
    sudo chmod +x /usr/local/bin/pishrink.sh
fi

TEMP_DIR="/tmp/rpi-image-modifier-$(pwgen -s1 8)"
ORIG_DIR="$(pwd -P)"

mkdir -vp "${TEMP_DIR}/mnt"
cd "${TEMP_DIR}"

NEEDS_CACHE_COPY=
if [ "${__ARG_CACHE}" -a -e /tmp/rpi-cached.img ]; then
    echo_green "Using cached image for ${__ARG_BASE_IMAGE_URL}"
    mv -v /tmp/rpi-cached.img rpi.img
else
    echo_green "Downloading ${__ARG_BASE_IMAGE_URL}..."
    wget -q -O rpi.img "${__ARG_BASE_IMAGE_URL}"
    NEEDS_CACHE_COPY=1
fi

case "$(file -b --mime-type rpi.img)" in
    application/x-xz) echo_green 'Decompressing with xz' && mv -v rpi.img rpi.img.xz && xz -T0 -d rpi.img.xz ;;
    application/gzip) echo_green 'Decompressing with gzip' && mv -v rpi.img rpi.img.gz && gzip -d rpi.img.gz ;;
    application/x-bzip2) echo_green 'Decompressing with bzip2' && mv -v rpi.img rpi.img.bz2 && bzip2 -d rpi.img.bz2 ;;
    application/x-lzma) echo_green 'Decompressing with lzma' && mv -v rpi.img rpi.img.lzma && lzma -d rpi.img.lzma ;;
esac

if [ "${__ARG_CACHE}" ] && [ "${NEEDS_CACHE_COPY}" ]; then
    echo_green 'Copying image for cache (got a cache miss)'
    cp -v rpi.img /tmp/rpi-cached.img
fi

echo_green "Temporarily expanding image to ${__ARG_IMAGE_MAXSIZE}"
fallocate -l "${__ARG_IMAGE_MAXSIZE}" rpi.img
LOOPBACK_DEV="$(sudo losetup -fP --show rpi.img)"
echo_green "Created loopback device ${LOOPBACK_DEV}"

echo_green 'Expanding partition'
sudo parted rpi.img resizepart 2 '100%FREE'
sudo losetup -d "${LOOPBACK_DEV}"
LOOPBACK_DEV="$(sudo losetup -fP --show rpi.img)"
echo_green "Re-created looped device ${LOOPBACK_DEV}"

echo_green 'Resizing second partition'
sudo resize2fs "${LOOPBACK_DEV}p2"

echo_green 'Mounting image'
sudo mount -v "${LOOPBACK_DEV}p2" "${TEMP_DIR}/mnt"

if grep -qF /boot/firmware "${TEMP_DIR}/mnt/etc/fstab"; then
    BOOT_MOUNTPOINT=/boot/firmware
else
    BOOT_MOUNTPOINT=/boot
fi

# Check if fstab mountpoint for boot partition exists (not the case for ubuntu)
if [ ! -d "${TEMP_DIR}/mnt/${BOOT_MOUNTPOINT}" ]; then
    mkdir -p "${TEMP_DIR}/mnt/${BOOT_MOUNTPOINT}"
fi

sudo mount -v "${LOOPBACK_DEV}p1" "${TEMP_DIR}/mnt/${BOOT_MOUNTPOINT}"

if [ "$__ARG_MOUNT_REPOSITORY" ]; then
    echo_green "Mounting ${ORIG_DIR} to /mounted-github-repo in image"
    sudo mkdir -v mnt/mounted-github-repo
    sudo mount -vo bind "${ORIG_DIR}" mnt/mounted-github-repo
fi

SCRIPT_NAME="/_$(pwgen -s1 12).sh"

if [ "$__ARG_RUN" ]; then
    echo_green "Generating script to run in image container"
    echo -e "set -e\n" | sudo tee "mnt${SCRIPT_NAME}"
    echo "$__ARG_RUN" | sudo tee -a "mnt${SCRIPT_NAME}"
else
    echo_green "Copying script to run in image container"
    sudo cp -v "${ORIG_DIR}/${__ARG_SCRIPT_PATH}" "mnt${SCRIPT_NAME}"
fi
sudo chmod +x "mnt${SCRIPT_NAME}"

echo_green "Running script in image container using ${__ARG_SHELL}"
EXTRA_SYSTEMD_NSPAWN_ARGS=()
if [ "${__ARG_ENV_VARS}" ]; then
    echo_green "Using environment variables: $(echo "${__ARG_ENV_VARS}" | sed 's/,/, /g')"
    for ENV_VAR in $(echo "${__ARG_ENV_VARS}" | sed 's/,/ /g'); do
        EXTRA_SYSTEMD_NSPAWN_ARGS+=("--setenv=${ENV_VAR}=${!ENV_VAR}")
    done
fi

# Make sure these two lines match, for debug printing
echo_green 'Running:' systemd-nspawn --directory="${TEMP_DIR}/mnt" --hostname=raspberrypi "${EXTRA_SYSTEMD_NSPAWN_ARGS[@]}" "${__ARG_SHELL}" "${SCRIPT_NAME}"
sudo systemd-nspawn --directory="${TEMP_DIR}/mnt" --hostname=raspberrypi "${EXTRA_SYSTEMD_NSPAWN_ARGS[@]}" "${__ARG_SHELL}" "${SCRIPT_NAME}"

echo_green '...Done!'

echo_green 'Cleaning up image'
sudo rm -v "mnt${SCRIPT_NAME}"
if [ "${__ARG_MOUNT_REPOSITORY}" ]; then
    sudo umount -v mnt/mounted-github-repo
    sudo rmdir -v mnt/mounted-github-repo
fi

echo_green 'Unmounting and removing loopback device'
sudo umount -vR mnt
sudo losetup -d "${LOOPBACK_DEV}"

if [ "${__ARG_SHRINK}" ]; then
    echo_green 'Shrinking image'
    sudo pishrink.sh -s rpi.img
else
    echo_green 'Not shrinking image'
fi

IMAGE_SIZE="$(du -b rpi.img | awk '{ print $1 }')"
echo_green "Image size: ${IMAGE_SIZE} bytes"

echo_green "Moving image to ${__ARG_IMAGE_PATH}"
mv -v rpi.img "${ORIG_DIR}/${__ARG_IMAGE_PATH}"

if [ "${__ARG_COMPRESS_WITH_XZ}" ]; then
    echo_green 'Running:' xz -T0 ${__ARG_EXTRA_XZ_ARGS} "${ORIG_DIR}/${__ARG_IMAGE_PATH}" '(This may take a while!)'
    xz -T0 ${__ARG_EXTRA_XZ_ARGS} "${ORIG_DIR}/${__ARG_IMAGE_PATH}"
    __ARG_IMAGE_PATH="${__ARG_IMAGE_PATH}.xz"
fi

echo_green "Cleaning up temporary directory ${TEMP_DIR}"
rm -rf "${TEMP_DIR}"

IMAGE_SHA256SUM="$(sha256sum "${ORIG_DIR}/${__ARG_IMAGE_PATH}" | awk '{ print $1 }')"

echo_green "Setting outputs: image-path=${__ARG_IMAGE_PATH}, image-size=${IMAGE_SIZE}, image-sha256sum=${IMAGE_SHA256SUM}"
echo "image-path=${__ARG_IMAGE_PATH}" >> "${GITHUB_OUTPUT}"
echo "image-size=${IMAGE_SIZE}" >> "${GITHUB_OUTPUT}"
echo "image-sha256sum=${IMAGE_SHA256SUM}" >> "${GITHUB_OUTPUT}"
