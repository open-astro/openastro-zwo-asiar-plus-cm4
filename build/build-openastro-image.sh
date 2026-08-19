#!/bin/bash
# Build the OpenAstro ZWO ASIAIR Plus image (Raspberry Pi CM4 based).
#
# Customizes a stock Raspberry Pi OS Lite (arm64, Trixie) image by running
# the OpenAstro layer (openastro/openastro-setup.sh) inside a chroot, then
# repacks it as a compressed, flashable image. The build host must be aarch64
# (native chroot - no qemu), e.g. an arm64 Debian box or a Pi itself.
#
# Usage: sudo build/build-openastro-image.sh <stock-raspios-lite.img[.xz]> [output.img.xz]
#
# Raspberry Pi OS images have two partitions: p1 bootfs (FAT32, mounted at
# /boot/firmware) and p2 rootfs (ext4). The rootfs is grown for the chroot
# package installs; RPi OS's own first-boot resize then expands it to fill
# the storage. The boot partition must be mounted in the chroot: the
# OpenAstro layer writes the ASIAIR Plus's power/USB GPIO line into
# /boot/firmware/config.txt.
#
# AlpacaBridge (latest from apt.openastro.net) is baked in.
set -euo pipefail

REPODIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:?usage: $0 <stock-raspios-lite.img[.xz]> [output.img.xz]}"
OUT="${2:-$REPODIR/images/openastro-zwo-asiair-plus-cm4.img.xz}"
ROOT_PART=2
BOOT_PART=1
BOOT_MNT="boot/firmware"          # relative to the rootfs mount
WORK="$(mktemp -d -p /var/tmp)"   # /var/tmp: disk-backed - the ~4G working image overflows a tmpfs /tmp
IMG="$WORK/openastro.img"
MNT="$WORK/rootfs"
LOOP=""

log() { echo "[build] $*"; }
cleanup() {
    set +e
    umount -lf "$MNT/dev/pts" "$MNT/dev" "$MNT/proc" "$MNT/sys" 2>/dev/null
    [ -n "$BOOT_PART" ] && mountpoint -q "$MNT/$BOOT_MNT" && umount -lf "$MNT/$BOOT_MNT"
    mountpoint -q "$MNT" && umount -lf "$MNT"
    [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

[ "$(id -u)" -eq 0 ] || { echo "Must run as root." >&2; exit 1; }
[ "$(uname -m)" = aarch64 ] || { echo "Build host must be aarch64 (native chroot)." >&2; exit 1; }

log "Staging source image..."
case "$SRC" in
    *.xz) xz -dc "$SRC" > "$IMG" ;;
    *)    cp --reflink=auto "$SRC" "$IMG" ;;
esac

# Grow the rootfs so there's room to install packages in the chroot. The
# unused space is zeroed and xz-compressed away at the end.
truncate -s +1500M "$IMG"
LOOP=$(losetup -fP --show "$IMG")
parted -s "$LOOP" resizepart "$ROOT_PART" 100%
partprobe "$LOOP" 2>/dev/null || true; sleep 1
e2fsck -fy "${LOOP}p${ROOT_PART}" >/dev/null 2>&1 || true
resize2fs "${LOOP}p${ROOT_PART}" >/dev/null 2>&1
mkdir -p "$MNT"
mount "${LOOP}p${ROOT_PART}" "$MNT"
[ -n "$BOOT_PART" ] && mount "${LOOP}p${BOOT_PART}" "$MNT/$BOOT_MNT"
log "rootfs free space: $(df -h "$MNT" | awk 'NR==2{print $4}')"

# chroot plumbing (native aarch64, networked via the host)
mount -t proc proc "$MNT/proc"
mount -t sysfs sys "$MNT/sys"
mount -o bind /dev "$MNT/dev"
mount -t devpts devpts "$MNT/dev/pts"
RESOLV_LINK=$(readlink "$MNT/etc/resolv.conf" 2>/dev/null || true)
rm -f "$MNT/etc/resolv.conf"
cp -L /etc/resolv.conf "$MNT/etc/resolv.conf" 2>/dev/null || echo 'nameserver 8.8.8.8' > "$MNT/etc/resolv.conf"

install -d "$MNT/opt/openastro"
install -m 0755 "$REPODIR/openastro/openastro-setup.sh" "$MNT/opt/openastro/"

log "Running openastro-setup.sh in chroot..."
chroot "$MNT" /bin/bash -c "cd /opt/openastro && ./openastro-setup.sh"

log "Cleaning image..."
chroot "$MNT" /bin/bash -c "apt-get clean" || true
rm -rf "$MNT"/var/lib/apt/lists/* "$MNT"/var/log/* "$MNT"/tmp/* 2>/dev/null || true
# Recreate the persistent-journal dir the log wipe just removed (matches
# openastro-setup.sh).
install -d -m 2755 "$MNT/var/log/journal"
chroot "$MNT" chgrp systemd-journal /var/log/journal 2>/dev/null || true
rm -f "$MNT"/etc/ssh/ssh_host_*           # regenerated per-device on first boot
: > "$MNT/etc/machine-id" 2>/dev/null || true
rm -f "$MNT/etc/resolv.conf"              # don't ship the build host's DNS
[ -n "${RESOLV_LINK:-}" ] && ln -sf "$RESOLV_LINK" "$MNT/etc/resolv.conf"  # restore runtime symlink

log "Zero-filling free space (so the image compresses small)..."
dd if=/dev/zero of="$MNT/ZERO.fill" bs=4M status=none 2>/dev/null || true
sync; rm -f "$MNT/ZERO.fill"; sync

umount -lf "$MNT/dev/pts" "$MNT/dev" "$MNT/proc" "$MNT/sys"
[ -n "$BOOT_PART" ] && umount "$MNT/$BOOT_MNT"
umount "$MNT"
losetup -d "$LOOP"; LOOP=""

log "Compressing -> $OUT"
mkdir -p "$(dirname "$OUT")"
xz -T0 -6 -c "$IMG" > "$OUT"
( cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256" )
log "Done: $OUT ($(du -h "$OUT" | cut -f1))"
