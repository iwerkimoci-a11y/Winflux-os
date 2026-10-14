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
cp /etc/resolv.conf "$CHROOT/etc/resolv.conf"

echo "==> [4/9] Memasang paket (kernel, XFCE, Picom, paket gaming, Secure Boot)"
cat > "$CHROOT/tmp/setup.sh" <<'CHROOT_EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C
dpkg --add-architecture i386
apt-get update
apt-get install -y --no-install-recommends \
  ubuntu-standard linux-generic casper initramfs-tools \
  shim-signed grub-efi-amd64-signed grub-pc-bin \
  xorg xfce4 xfce4-goodies lightdm lightdm-gtk-greeter \
  picom plank arc-theme papirus-icon-theme fonts-noto \
  network-manager network-manager-gnome pipewire-audio pavucontrol \
  firefox-esr 2>/dev/null || true
# firefox-esr tidak ada di repo Ubuntu; lanjutkan tanpa itu
apt-get install -y --no-install-recommends \
  ubuntu-standard linux-generic casper initramfs-tools \
  linux-firmware amd64-microcode intel-microcode \
  shim-signed grub-efi-amd64-signed grub-pc-bin \
  xorg xfce4 xfce4-goodies lightdm lightdm-gtk-greeter \
  picom plank arc-theme papirus-icon-theme fonts-noto \
  network-manager network-manager-gnome pipewire-audio pavucontrol \
  mesa-vulkan-drivers libgl1-mesa-dri vulkan-tools mesa-utils \
  gamemode mangohud steam-installer wine64 \
  sudo nano file-roller thunar-archive-plugin \
  calamares efibootmgr os-prober

# Konfigurasi installer (jika paketnya tersedia)
apt-get install -y calamares-settings-ubuntu || echo "PERINGATAN: calamares-settings-ubuntu tidak tersedia"

# --- Driver tambahan: WiFi/Bluetooth, audio, GPU, printer, disk, guest VM ---
# Dipasang satu per satu supaya paket yang tidak ada tidak menggagalkan build.
for pkg in wpasupplicant wireless-tools iw rfkill bluez blueman \
           alsa-utils pulseaudio-utils firmware-sof-signed \
           xserver-xorg-video-all xserver-xorg-input-all \
           mesa-va-drivers mesa-vdpau-drivers vainfo intel-media-va-driver \
           cups printer-driver-all system-config-printer sane-utils \
           ntfs-3g exfatprogs ubuntu-drivers-common \
           open-vm-tools-desktop spice-vdagent \
           virtualbox-guest-utils virtualbox-guest-x11; do
  apt-get install -y --no-install-recommends "$pkg" || echo "PERINGATAN: $pkg dilewati"
done

# Modul kernel tambahan (driver WiFi/perangkat lain yang tidak ada di modul inti)
KVER_C=$(ls /lib/modules | sort -V | tail -1)
apt-get install -y "linux-modules-extra-$KVER_C" || echo "PERINGATAN: linux-modules-extra dilewati"

# NVIDIA proprietary: modul berlabel Canonical, jadi tetap jalan dengan Secure Boot
for v in 580 570 550; do
  if apt-get install -y "nvidia-driver-$v" "linux-modules-nvidia-$v-generic"; then
    echo "Driver NVIDIA $v terpasang"; break
  fi
done

# Pastikan firmware GPU (amdgpu) ikut masuk ke initramfs
update-initramfs -u -k all

# --- Tema & Picom ala Windows 11 ---
mkdir -p /etc/skel/.config/picom /etc/skel/.config/autostart \
         /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml
cat > /etc/skel/.config/picom/picom.conf <<'EOF'
backend = "glx";
vsync = true;
corner-radius = 10;
rounded-corners-exclude = ["window_type = 'dock'", "window_type = 'desktop'"];
shadow = true;
shadow-radius = 14;
shadow-opacity = 0.35;
fading = true;
fade-in-step = 0.06;
fade-out-step = 0.06;
inactive-opacity = 0.97;
blur-method = "dual_kawase";
blur-strength = 6;
blur-background = true;
blur-background-exclude = ["window_type = 'desktop'", "class_g = 'Plank'"];
opacity-rule = [
  "88:class_g = 'Xfce4-terminal'",
  "90:class_g = 'Xfce4-panel'",
  "90:class_g = 'Thunar'"
];
unredir-if-possible = true;   # matikan compositing saat fullscreen (gaming)
EOF
cat > /etc/skel/.config/autostart/picom.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Picom
Exec=picom --config %h/.config/picom/picom.conf
EOF
cat > /etc/skel/.config/autostart/plank.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Dock
Exec=plank
EOF
cat > /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="ThemeName" type="string" value="Arc-Dark"/>
    <property name="IconThemeName" type="string" value="Papirus-Dark"/>
  </property>
</channel>
EOF
# Matikan compositor bawaan XFWM agar tidak bentrok dengan Picom
cat > /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="false"/>
    <property name="theme" type="string" value="Arc-Dark"/>
    <property name="button_layout" type="string" value="|HMC"/>
  </property>
</channel>
EOF

# --- Animasi halus: picom v12 (animasi bawaan) dibangun dari sumber. Opsional:
# jika gagal, sistem tetap memakai picom bawaan Ubuntu tanpa animasi buka/tutup.
if (
  set -e
  apt-get install -y git ca-certificates meson ninja-build gcc pkg-config \
    libxcb1-dev libxcb-damage0-dev libxcb-xfixes0-dev libxcb-shape0-dev \
    libxcb-render-util0-dev libxcb-render0-dev libxcb-randr0-dev \
    libxcb-composite0-dev libxcb-image0-dev libxcb-present-dev libxcb-glx0-dev \
    libxcb-xinerama0-dev libxcb-util-dev libxcb-sync-dev libx11-xcb-dev \
    libpixman-1-dev libdbus-1-dev libconfig-dev libev-dev libpcre2-dev \
    libepoxy-dev uthash-dev libgl-dev
  git clone https://github.com/yshui/picom /tmp/picom-src
  cd /tmp/picom-src
  git checkout "$(git tag -l 'v12*' | sort -V | tail -1)"
  meson setup --buildtype=release build
  ninja -C build
  ninja -C build install
  /usr/local/bin/picom --version
); then
  echo "picom v12 berhasil dibangun, mengaktifkan animasi"
  cat >> /etc/skel/.config/picom/picom.conf <<'EOF'

animations = (
  { triggers = ["open", "show"];    preset = "appear";    duration = 0.18; },
  { triggers = ["close", "hide"];   preset = "disappear"; duration = 0.15; }
);
EOF
else
  echo "PERINGATAN: picom v12 gagal dibangun, memakai picom bawaan (tanpa animasi buka/tutup)"
fi
rm -rf /tmp/picom-src

# --- Autologin untuk sesi live ---
mkdir -p /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/50-winflux.conf <<'EOF'
[Seat:*]
autologin-user=ubuntu
autologin-user-timeout=0
user-session=xfce
EOF

# --- Shortcut installer di desktop (sesi live) ---
mkdir -p /etc/skel/Desktop
cat > /etc/skel/Desktop/install-winflux.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Install WinFlux OS
Comment=Pasang WinFlux OS ke disk
Exec=sudo -E calamares
Icon=system-software-install
Terminal=false
EOF
chmod +x /etc/skel/Desktop/install-winflux.desktop

# Identitas OS
sed -i 's/^PRETTY_NAME=.*/PRETTY_NAME="WinFlux OS 1.0 (Ubuntu 24.04 LTS)"/' /etc/os-release || true

systemctl enable NetworkManager lightdm || true
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/setup.sh
CHROOT_EOF
chroot "$CHROOT" /bin/bash /tmp/setup.sh

echo "==> [5/9] Menyalin kernel, initrd, dan binari Secure Boot"
KVER=$(basename "$(ls "$CHROOT"/boot/vmlinuz-* | sort -V | tail -1)" | sed 's/vmlinuz-//')
cp "$CHROOT/boot/vmlinuz-$KVER"   "$IMG/casper/vmlinuz"
cp "$CHROOT/boot/initrd.img-$KVER" "$IMG/casper/initrd"
cp "$CHROOT/usr/lib/shim/shimx64.efi.signed"            "$IMG/EFI/boot/bootx64.efi"
cp "$CHROOT/usr/lib/shim/mmx64.efi"                      "$IMG/EFI/boot/mmx64.efi"
cp "$CHROOT/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed" "$IMG/EFI/boot/grubx64.efi"

echo "==> [6/9] Membuat squashfs (kompresi, agak lama)"
chroot "$CHROOT" dpkg-query -W --showformat='${Package} ${Version}\n' > "$IMG/casper/filesystem.manifest"
cleanup
mksquashfs "$CHROOT" "$IMG/casper/filesystem.squashfs" -comp xz -b 1M -noappend \
  -e boot/vmlinuz* -e boot/initrd.img*
printf $(du -sx --block-size=1 "$CHROOT" | cut -f1) > "$IMG/casper/filesystem.size"

echo "==> [7/9] Konfigurasi GRUB (BIOS + UEFI)"
echo "WinFlux OS 1.0 - Ubuntu 24.04 LTS" > "$IMG/.disk/info"
cat > "$IMG/boot/grub/grub.cfg" <<'EOF'
set default=0
set timeout=5
insmod all_video
menuentry "WinFlux OS (Live)" {
    linux  /casper/vmlinuz boot=casper quiet splash ---
    initrd /casper/initrd
}
menuentry "WinFlux OS (Safe graphics)" {
    linux  /casper/vmlinuz boot=casper nomodeset ---
    initrd /casper/initrd
}
EOF
# grub.cfg kecil di partisi EFI yang mencari ISO lalu memuat config utama
cat > "$IMG/EFI/boot/grub.cfg" <<'EOF'
search --set=root --file /.disk/info
set prefix=($root)/boot/grub
configfile $prefix/grub.cfg
EOF

# Image FAT untuk boot UEFI
dd if=/dev/zero of="$WORK/efi.img" bs=1M count=8
mkfs.vfat "$WORK/efi.img"
mmd -i "$WORK/efi.img" ::/EFI ::/EFI/boot
mcopy -i "$WORK/efi.img" "$IMG/EFI/boot/"* ::/EFI/boot/
cp "$WORK/efi.img" "$IMG/boot/grub/efi.img"

# Image BIOS (El Torito)
mkdir -p "$IMG/boot/grub/i386-pc"
grub-mkimage -O i386-pc-eltorito -p /boot/grub \
  -o "$IMG/boot/grub/i386-pc/eltorito.img" \
  biosdisk iso9660 normal linux search search_fs_file configfile all_video
cp -r /usr/lib/grub/i386-pc/*.mod "$IMG/boot/grub/i386-pc/" 2>/dev/null || true

echo "==> [8/9] Menghitung checksum & membuat ISO"
( cd "$IMG" && find . -type f ! -name md5sum.txt -print0 | xargs -0 md5sum > md5sum.txt )
xorriso -as mkisofs -iso-level 3 -full-iso9660-filenames -volid "$VOLID" \
  -eltorito-boot boot/grub/i386-pc/eltorito.img \
    -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info \
  -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot \
  -isohybrid-gpt-basdat \
  -output "$OUT" "$IMG"

echo "==> [9/9] Selesai"
sha256sum "$OUT" | tee "$OUT.sha256"
echo "ISO: $OUT"
echo "Tulis ke flashdisk: sudo dd if=\"$OUT\" of=/dev/sdX bs=4M status=progress oflag=sync"
