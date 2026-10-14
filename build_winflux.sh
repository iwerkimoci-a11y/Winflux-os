#!/usr/bin/env bash
# build_winflux.sh — membangun ISO WinFlux OS (Ubuntu 24.04 LTS + WinFlux DE)
# Jalankan di Ubuntu 24.04 (PC/VM) dengan internet, ruang disk bebas >= 15 GB:
#   sudo ./build_winflux.sh
# Hasil: ./winflux-os-<tanggal>.iso (hybrid BIOS + UEFI, Secure Boot via shim Canonical)
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Jalankan dengan sudo."; exit 1; }

RELEASE=noble
MIRROR=http://archive.ubuntu.com/ubuntu
WORK="$(pwd)/build"
CHROOT="$WORK/chroot"
IMG="$WORK/image"
VOLID="WINFLUX_OS"
OUT="$(pwd)/winflux-os-$(date +%Y%m%d).iso"

echo "==> [1/9] Memasang dependensi host"
apt-get update
apt-get install -y debootstrap squashfs-tools xorriso mtools dosfstools \
  grub-pc-bin grub-efi-amd64-bin grub-common isolinux

cleanup() {
  for m in run sys proc dev/pts dev; do
    mountpoint -q "$CHROOT/$m" 2>/dev/null && umount -lf "$CHROOT/$m" || true
  done
}
trap cleanup EXIT

rm -rf "$WORK"
mkdir -p "$CHROOT" "$IMG"/{casper,boot/grub,EFI/boot,.disk}

echo "==> [2/9] debootstrap $RELEASE (butuh beberapa menit)"
debootstrap --arch=amd64 --variant=minbase "$RELEASE" "$CHROOT" "$MIRROR"

mount --bind /dev "$CHROOT/dev"
mount -t devpts devpts "$CHROOT/dev/pts"
mount -t proc proc "$CHROOT/proc"
mount -t sysfs sys "$CHROOT/sys"
mount -t tmpfs tmpfs "$CHROOT/run"

echo "==> [3/9] Konfigurasi dasar sistem"
cat > "$CHROOT/etc/apt/sources.list" <<EOF
deb $MIRROR $RELEASE main restricted universe multiverse
deb $MIRROR $RELEASE-updates main restricted universe multiverse
deb $MIRROR $RELEASE-security main restricted universe multiverse
EOF
echo "winflux" > "$CHROOT/etc/hostname"
echo "127.0.0.1 localhost winflux" > "$CHROOT/etc/hosts"
