#!/bin/bash
# OpenAstro ASIAIR Plus flash tool (Linux + macOS).
#
# Just run it:   ./openastro-flash.sh
#
# You get a menu:
#   1) Backup   - save the current eMMC (stock ZWO OS) to a compressed
#                 image + .sha256 in images/
#   2) Flash    - write the OpenAstro image to the eMMC (downloads the
#                 latest release image automatically if not present)
#   3) Restore  - write a saved backup back (return to stock ZWO)
#
# Everything else is automatic: rpiboot is installed on first use, the eMMC
# is detected as the disk that newly appears (never guessed), size-checked
# (~32 GB), and you confirm the device before anything is written.
#
# ALWAYS make a backup before the first flash - the stock ZWO OS is not
# downloadable anywhere; your backup is the only way back.
#
# Scripting: the menu choices also work as subcommands -
#   ./openastro-flash.sh backup  [out.img.xz]
#   ./openastro-flash.sh flash   [image.img.xz]
#   ./openastro-flash.sh restore [backup.img.xz]
set -euo pipefail

REPODIR="$(cd "$(dirname "$0")/.." && pwd)"
IMAGESDIR="$REPODIR/images"
OS="$(uname -s)"
RELEASE_API="https://api.github.com/repos/open-astro/openastro-zwo-asiar-plus-cm4/releases/latest"
IMAGE_NAME="openastro-zwo-asiair-plus-cm4.img.xz"

log()  { echo "[flash] $*"; }
die()  { echo "[flash] ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required - $2"; }

# ------------------------------------------------------------
# rpiboot (installed automatically on first use)
# ------------------------------------------------------------
ensure_rpiboot() {
    command -v rpiboot >/dev/null 2>&1 && return 0
    echo
    log "rpiboot (Raspberry Pi usbboot) is needed to talk to the ASIAIR Plus's eMMC."
    read -r -p "Install it now? [Y/n] " a
    case "$a" in [nN]*) die "rpiboot is required - aborting." ;; esac
    case "$OS" in
    Linux)
        log "Installing build deps (sudo apt-get)..."
        sudo apt-get update -qq
        sudo apt-get install -y -qq git libusb-1.0-0-dev pkg-config build-essential
        local src; src="$(mktemp -d)"
        log "Building rpiboot from raspberrypi/usbboot..."
        git clone --depth 1 https://github.com/raspberrypi/usbboot "$src/usbboot"
        make -C "$src/usbboot"
        sudo make -C "$src/usbboot" install
        rm -rf "$src"
        ;;
    Darwin)
        need brew "install Homebrew from https://brew.sh first"
        log "Installing rpiboot via Homebrew..."
        brew install rpiboot || {
            # No bottle for this platform: build from source.
            brew install libusb pkg-config
            local src; src="$(mktemp -d)"
            git clone --depth 1 https://github.com/raspberrypi/usbboot "$src/usbboot"
            make -C "$src/usbboot"
            sudo install -m 755 "$src/usbboot/rpiboot" /usr/local/bin/rpiboot
            sudo mkdir -p /usr/local/share/rpiboot
            sudo cp -R "$src/usbboot/mass-storage-gadget64" /usr/local/share/rpiboot/ 2>/dev/null || true
            rm -rf "$src"
        }
        ;;
    *) die "unsupported OS '$OS' (use openastro-flash.ps1 on Windows)" ;;
    esac
    log "rpiboot installed: $(command -v rpiboot)"
}

# ------------------------------------------------------------
# OpenAstro image (downloaded automatically if missing)
# ------------------------------------------------------------
fetch_openastro_image() {
    IMAGE="$IMAGESDIR/$IMAGE_NAME"
    [ -f "$IMAGE" ] && { log "Using local image: $IMAGE"; return 0; }
    need curl "install curl"
    echo
    log "OpenAstro image not found locally - fetching the latest release..."
    local url sha_url
    url="$(curl -fsSL "$RELEASE_API" | grep -o "https://[^\"]*/$IMAGE_NAME" | head -1)"
    [ -n "$url" ] || die "could not find $IMAGE_NAME in the latest GitHub release."
    sha_url="$(curl -fsSL "$RELEASE_API" | grep -o "https://[^\"]*/$IMAGE_NAME.sha256" | head -1)"
    mkdir -p "$IMAGESDIR"
    log "Downloading $url (~550 MB)..."
    curl -fL --progress-bar -o "$IMAGE.part" "$url"
    if [ -n "$sha_url" ]; then
        curl -fsSL -o "$IMAGE.sha256" "$sha_url"
        log "Verifying checksum..."
        local want got
        want="$(awk '{print $1}' "$IMAGE.sha256")"
        if [ "$OS" = Darwin ]; then got="$(shasum -a 256 "$IMAGE.part" | awk '{print $1}')"
        else got="$(sha256sum "$IMAGE.part" | awk '{print $1}')"; fi
        [ "$want" = "$got" ] || die "checksum mismatch on downloaded image - delete $IMAGE.part and retry."
        log "Checksum OK."
    fi
    mv "$IMAGE.part" "$IMAGE"
    log "Image saved to $IMAGE"
}

# ------------------------------------------------------------
# Device discovery
# ------------------------------------------------------------
# The eMMC is identified by the RPi mass-storage gadget's USB identity
# (vendor/model "RPi-MSD"), with "disk that newly appeared since before
# rpiboot" as a fallback - never guessed.
list_disks() {
    case "$OS" in
    Linux)  lsblk -dno NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}' ;;
    Darwin) diskutil list | awk '/^\/dev\/disk/{print $1}' | sed 's|/dev/||' ;;
    esac
}

find_rpi_msd_disk() {
    case "$OS" in
    Linux)
        lsblk -dno NAME,VENDOR,MODEL 2>/dev/null |
            awk 'tolower($0) ~ /rpi|raspberry/ {print $1; exit}'
        ;;
    Darwin)
        local x
        for x in $(list_disks); do
            if diskutil info "/dev/$x" 2>/dev/null | grep -qiE 'rpi|raspberry'; then
                echo "$x"; return 0
            fi
        done
        ;;
    esac
}

run_rpiboot_and_find_device() {
    ensure_rpiboot
    local before after new d
    before="$(list_disks)"

    echo
    echo "Put the ASIAIR Plus in USB device-boot mode now:"
    echo "  1. Make sure the ASIAIR Plus is unplugged (no power)."
    echo "  2. Open the case and short the two nRPIBOOT boot pads on the"
    echo "     carrier board with a jumper wire (keep them shorted)."
    echo "  3. Connect a USB-A (computer) to USB-C (ASIAIR Plus) data cable."
    echo "  4. Connect 12V DC power - unlike other CM4 boards, the ASIAIR"
    echo "     Plus does NOT power up from the USB cable alone; it needs"
    echo "     12V power connected to turn on."
    echo
    read -r -p "Press Enter when the pins are shorted and the USB cable is connected... " _

    # Maybe the gadget is already up from a previous run - skip rpiboot then.
    d="$(find_rpi_msd_disk || true)"
    if [ -n "$d" ]; then
        log "RPi mass-storage gadget already present: /dev/$d"
        DEVICE="/dev/$d"
    else
        log "Running rpiboot (waits for the CM4)..."
        # The mass-storage gadget exports the eMMC as a USB disk. Plain
        # 'rpiboot' does NOT load it (it just boots the board normally), so
        # try the gadget dir name and the known install locations.
        sudo rpiboot -d mass-storage-gadget64 ||
            sudo rpiboot -d /usr/share/rpiboot/mass-storage-gadget64 ||
            sudo rpiboot -d /usr/local/share/rpiboot/mass-storage-gadget64 ||
            die "rpiboot could not load the mass-storage gadget (mass-storage-gadget64 not found)."

        log "Waiting for the eMMC to appear as a USB disk..."
        for _ in $(seq 1 60); do
            # Prefer the gadget's USB identity (works even if the disk node
            # already existed); fall back to the newly-appeared-disk diff.
            d="$(find_rpi_msd_disk || true)"
            if [ -z "$d" ]; then
                after="$(list_disks)"
                d="$(comm -13 <(echo "$before" | sort) <(echo "$after" | sort) | head -1 || true)"
            fi
            if [ -n "$d" ]; then
                DEVICE="/dev/$d"
                break
            fi
            sleep 1
        done
    fi
    [ -n "${DEVICE:-}" ] || die "eMMC never appeared as a disk. Check the USB cable (must be data-capable) and boot mode."

    # Sanity: the ASIAIR Plus eMMC is 32 GB (~29 GiB); refuse anything wildly
    # different so a wrong disk can't be nuked.
    local size_bytes size_gb
    case "$OS" in
    Linux)  size_bytes="$(lsblk -bdno SIZE "$DEVICE")" ;;
    Darwin) size_bytes="$(diskutil info "$DEVICE" | sed -n 's/.*(\([0-9][0-9]*\) Bytes).*/\1/p' | head -1)" ;;
    esac
    size_gb=$(( ${size_bytes:-0} / 1000000000 ))
    log "Found new USB disk: $DEVICE (${size_gb} GB)"
    if [ "$size_gb" -lt 28 ] || [ "$size_gb" -gt 36 ]; then
        die "$DEVICE is ${size_gb} GB - not a 32 GB ASIAIR Plus eMMC. Aborting."
    fi

    echo
    echo "  >>> Target device: $DEVICE (${size_gb} GB) <<<"
    echo
    read -r -p "Type the device path again to confirm: " confirm
    [ "$confirm" = "$DEVICE" ] || die "confirmation mismatch - aborting."
}

unmount_device() {
    case "$OS" in
    Linux)  for p in "${DEVICE}"?*; do sudo umount "$p" 2>/dev/null || true; done ;;
    Darwin) diskutil unmountDisk "$DEVICE" >/dev/null ;;
    esac
}

raw_device() {
    # macOS: the raw (character) node is dramatically faster for dd.
    case "$OS" in
    Darwin) echo "${DEVICE/\/dev\/disk//dev/rdisk}" ;;
    *)      echo "$DEVICE" ;;
    esac
}

# ------------------------------------------------------------
# Commands
# ------------------------------------------------------------
have_backup() { compgen -G "$IMAGESDIR/asiair-stock-backup-*.img.xz" >/dev/null 2>&1; }
latest_backup() { ls -t "$IMAGESDIR"/asiair-stock-backup-*.img.xz 2>/dev/null | head -1; }

cmd_backup() {
    local out="${1:-$IMAGESDIR/asiair-stock-backup-$(date +%Y%m%d).img.xz}"
    need xz "install xz-utils"
    [ -e "$out" ] && die "$out already exists - refusing to overwrite a backup."
    run_rpiboot_and_find_device
    unmount_device
    mkdir -p "$(dirname "$out")"
    log "Reading eMMC -> $out (32 GB read, takes a while)..."
    set -o pipefail
    if [ "$OS" = Darwin ]; then
        sudo dd if="$(raw_device)" bs=4m | xz -T0 -2 > "$out"
        log "Read complete. Computing SHA-256 checksum (takes a few minutes, no output)..."
        ( cd "$(dirname "$out")" && shasum -a 256 "$(basename "$out")" > "$(basename "$out").sha256" )
    else
        sudo dd if="$(raw_device)" bs=4M status=progress | xz -T0 -2 > "$out"
        log "Read complete. Computing SHA-256 checksum (takes a few minutes, no output)..."
        ( cd "$(dirname "$out")" && sha256sum "$(basename "$out")" > "$(basename "$out").sha256" )
    fi
    log "Backup complete: $out ($(du -h "$out" | cut -f1))"
    log "Keep this file safe - it is the way back to the stock ZWO OS."
}

write_image() {
    local img="$1" label="$2"
    [ -f "$img" ] || die "image not found: $img"
    run_rpiboot_and_find_device
    unmount_device
    set -o pipefail
    decompress() {
        case "$img" in
        *.xz) xz -dc "$img" ;;
        *.gz) gzip -dc "$img" ;;
        *)    cat "$img" ;;
        esac
    }
    sha_cmd() {
        if [ "$OS" = Darwin ]; then shasum -a 256; else sha256sum; fi
    }

    # Hash and count the bytes as they stream to the disk, so the write can
    # be verified afterwards without decompressing the image again.
    local tmp want bytes got
    tmp="$(mktemp -d)"
    log "Writing $label -> $DEVICE ..."
    log "(after the last progress line, dd flushes the final data to the eMMC -"
    log " it can sit there a minute with the activity LED blinking; that's normal)"
    if [ "$OS" = Darwin ]; then
        decompress | tee >(sha_cmd | awk '{print $1}' > "$tmp/hash") >(wc -c > "$tmp/size") | sudo dd of="$(raw_device)" bs=4m
    else
        # oflag=direct bypasses the page cache so the progress numbers track
        # what has actually reached the eMMC, instead of racing ahead and
        # then silently stalling on one huge flush at the end.
        decompress | tee >(sha_cmd | awk '{print $1}' > "$tmp/hash") >(wc -c > "$tmp/size") | sudo dd of="$(raw_device)" bs=4M status=progress oflag=direct conv=fsync
    fi
    log "Write complete. Syncing..."
    sync
    # The tee >(...) hashers run asynchronously - wait for their output files.
    for _ in $(seq 1 50); do
        [ -s "$tmp/hash" ] && [ -s "$tmp/size" ] && break
        sleep 0.2
    done
    want="$(cat "$tmp/hash")"
    bytes="$(tr -dc 0-9 < "$tmp/size")"
    rm -rf "$tmp"
    [ -n "$want" ] && [ -n "$bytes" ] || die "internal error: checksum of the written stream was not captured."

    log "Verifying: reading back $((bytes / 1000000)) MB from the eMMC and comparing checksums..."
    if [ "$OS" = Darwin ]; then
        got="$( { sudo dd if="$(raw_device)" bs=4m 2>/dev/null || true; } | head -c "$bytes" | sha_cmd | awk '{print $1}')"
    else
        got="$(sudo dd if="$(raw_device)" bs=4M iflag=count_bytes count="$bytes" status=progress | sha_cmd | awk '{print $1}')"
    fi
    [ "$want" = "$got" ] || die "VERIFICATION FAILED - the data on the eMMC does not match the image. Do not boot it; re-run the flash (check the USB cable/port)."
    log "Verification PASSED - the eMMC matches the image."

    case "$OS" in Darwin) diskutil eject "$DEVICE" || true ;; esac
    log "$label written and verified. Disconnect USB, remove the jumper, and power-cycle."
}

cmd_flash() {
    local img="${1:-}"
    if [ -z "$img" ]; then
        fetch_openastro_image
        img="$IMAGE"
    fi
    echo
    echo "This OVERWRITES the eMMC with the OpenAstro image."
    if ! have_backup; then
        echo "No stock backup found in $IMAGESDIR - the stock ZWO OS is NOT"
        echo "downloadable anywhere; a backup is the only way back to stock."
        read -r -p "Make a backup first? [Y/n] " a
        case "$a" in [nN]*) ;; *)
            cmd_backup
            echo
            echo "Backup done - now the flash. Unplug the USB cable, then plug it"
            echo "back in (keep the jumper shorted) so the board can re-enter boot mode."
            ;;
        esac
    fi
    read -r -p "Continue with the flash? [y/N] " a; case "$a" in [yY]) ;; *) exit 1 ;; esac
    write_image "$img" "OpenAstro image"
}

cmd_restore() {
    local img="${1:-}"
    if [ -z "$img" ]; then
        img="$(latest_backup || true)"
        [ -n "$img" ] || die "no backup found in $IMAGESDIR - pass one: $0 restore <backup.img.xz>"
    fi
    echo
    echo "This OVERWRITES the eMMC with the stock ZWO backup:"
    echo "  $img"
    read -r -p "Continue? [y/N] " a; case "$a" in [yY]) ;; *) exit 1 ;; esac
    write_image "$img" "stock ZWO backup"
}

menu() {
    echo
    echo "OpenAstro ASIAIR Plus flash tool"
    echo "==============================="
    echo
    echo "  1) Backup  - save the stock ZWO OS from the eMMC (do this first!)"
    echo "  2) Flash   - write the OpenAstro image to the eMMC"
    echo "  3) Restore - write a stock backup back to the eMMC"
    echo "  q) Quit"
    echo
    read -r -p "Choose [1/2/3/q]: " choice
    case "$choice" in
    1) cmd_backup ;;
    2) cmd_flash ;;
    3) cmd_restore ;;
    q|Q) exit 0 ;;
    *) die "invalid choice '$choice'" ;;
    esac
}

case "${1:-}" in
"")              menu ;;
backup)          shift; cmd_backup "$@" ;;
flash)           shift; cmd_flash "$@" ;;
restore)         shift; cmd_restore "$@" ;;
install-rpiboot) ensure_rpiboot ;;
-h|--help|help)  sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//' ;;
*)               die "unknown command '${1}' - run with no arguments for the menu." ;;
esac
