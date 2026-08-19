#!/bin/bash
# OpenAstro layer for the ZWO ASIAIR Plus (Raspberry Pi CM4 based).
#
# NOTE: first-generation CM4-based ASIAIR Plus only - NOT the Rockchip
# (RK3568) ASIAIR Plus revisions.
#
# This turns a stock Raspberry Pi OS Lite (arm64, Trixie) image into the
# OpenAstro OS for the ASIAIR Plus: a WiFi access point (OpenAstro-XXXX /
# 12345678), baked-in credentials (astro/astro, no first-boot wizard), the
# ASIAIR Plus hardware enablement (12V power outputs, Renesas xHCI
# firmware), and the plumbing AlpacaBridge expects. On first boot the SSID
# gains a per-board suffix from the wlan0 MAC (e.g. OpenAstro-915D) so
# multiple boards don't collide.
#
# Hardware layer (per https://www.openastro.net/docs/sbc-install/zwo-asiair-plus-cm4):
#   - config.txt gpio=12,13,26,18=op,dh,pu - GPIO 12/13/26/18 switch the
#     12V DC power outputs on at boot.
#   - Renesas uPD72020x xHCI firmware at /lib/firmware/renesas_usb_fw.mem
#     (the ASIAIR Plus's USB ports hang off a Renesas xhci-pci controller
#     that needs this firmware), baked into the initramfs.
#
# AlpacaBridge is preinstalled from the OpenAstro apt repository
# (apt.openastro.net) and stays current with apt upgrade.
#
# The AP is a NetworkManager keyfile connection (mode=ap, ipv4.method=shared)
# on a dedicated virtual AP interface (ap0): the CM4's brcmfmac radio
# supports concurrent AP+STA, so the hotspot stays up while wlan0 is free to
# join the user's network from the AlpacaBridge WiFi card (the Orange Pi 4
# Pro / Raspberry Pi pattern). The AP autoconnects at boot so the board is
# always reachable via its own hotspot even when it can't be reached over
# the local network.
#
# Idempotent: safe to re-run. Runs as root, either in the image-build chroot
# (build/build-openastro-image.sh) or post-flash on a booted board.

set -euo pipefail

# --- Config (override via env) ---
AP_SSID="${AP_SSID:-OpenAstro}"
AP_PASSPHRASE="${AP_PASSPHRASE:-12345678}"
AP_IP="${AP_IP:-172.24.1.1}"                # pinned (not NM's 10.42.0.1 default) so docs can give a fixed bridge IP
AP_BAND="${AP_BAND:-bg}"                    # 2.4 GHz: range + brcmfmac AP+STA is single-channel; "a"/36 = 5 GHz
AP_CHANNEL="${AP_CHANNEL:-6}"
AP_COUNTRY="${AP_COUNTRY:-US}"

log() { echo "[openastro] $*"; }
[ "$(id -u)" -eq 0 ] || { echo "Must run as root." >&2; exit 1; }

# ============================================================
# Packages
# ============================================================
log "Installing packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# python3-rpi-lgpio: RPi.GPIO-compatible API on Trixie, for the buzzer.
apt-get install -y -qq \
    network-manager dnsmasq-base nftables iw wireless-regdb \
    python3-rpi-lgpio \
    >/dev/null

# ============================================================
# ASIAIR Plus hardware: 12V power outputs
# ============================================================
# GPIO 12, 13, 26, 18 switch the ASIAIR Plus's 12V DC power outputs. Drive
# them all high (op,dh) with pull-ups (pu) from the firmware at boot, so the
# DC outputs are live before Linux even starts - AlpacaBridge then toggles
# them at runtime via GPIO.
log "Enabling 12V power outputs (config.txt)..."
GPIO_LINE="gpio=12,13,26,18=op,dh,pu"
CONFIG_TXT="/boot/firmware/config.txt"
if [ -f "$CONFIG_TXT" ]; then
    grep -qxF "$GPIO_LINE" "$CONFIG_TXT" || {
        printf '\n# OpenAstro ASIAIR Plus: 12V power outputs\n%s\n' \
            "$GPIO_LINE" >> "$CONFIG_TXT"
    }
else
    echo "WARNING: $CONFIG_TXT not found - boot partition not mounted?" >&2
    exit 1
fi

# The ASIAIR Plus's USB ports sit behind a Renesas uPD72020x xHCI controller
# (xhci-pci-renesas) that needs firmware the stock image doesn't ship.
# Without it the USB ports are dead. Bake it in and rebuild the initramfs
# so the controller comes up at boot. Verify on hardware with:
#   dmesg | grep -i renesas
log "Installing Renesas uPD72020x USB firmware..."
RENESAS_FW_URL="${RENESAS_FW_URL:-https://raw.githubusercontent.com/open-astro/uPD72020x/master/UPDATE.mem}"
curl -fsSL "$RENESAS_FW_URL" -o /lib/firmware/renesas_usb_fw.mem
update-initramfs -u >/dev/null 2>&1 || update-initramfs -c -k all >/dev/null

# ============================================================
# Buzzer: OpenAstro jingle on boot (piezo on BCM GPIO 19)
# ============================================================
# The ASIAIR Plus has a piezo buzzer reachable from GPIO 19, same as the
# ASIAIR Pro (not an ALSA device; verified audibly on live ASIAIR Plus CM4
# hardware). Same jingle and mechanism as openastro-zwo-asiar-pro and
# openastro-touptek-stellavita (which uses GPIO 12).
log "Installing buzzer jingle..."
cat > /usr/local/sbin/openastro-beep <<'EOF'
#!/usr/bin/python3
# OpenAstro jingle on the ASIAIR Plus piezo (BCM GPIO 19)
# usage: openastro-beep [gpio]
import RPi.GPIO as GPIO
import time
import sys

PIN = int(sys.argv[1]) if len(sys.argv) > 1 else 19

# (freq_hz, duration_s) - 0 freq = rest
# "O-pen-As-tro!" rising motif, then a little starlight trill
TUNE = [
    (523, 0.12), (0, 0.03),   # C5  O-
    (659, 0.12), (0, 0.03),   # E5  pen
    (784, 0.12), (0, 0.03),   # G5  As-
    (1047, 0.22), (0, 0.08),  # C6  tro!
    (1319, 0.07), (1568, 0.07), (2093, 0.18),  # E6 G6 C7 sparkle
]

def tone(hz, dur):
    if hz == 0:
        time.sleep(dur)
        return
    half = 1.0 / (2 * hz)
    cycles = int(dur * hz)
    for _ in range(cycles):
        GPIO.output(PIN, GPIO.LOW)
        time.sleep(half)
        GPIO.output(PIN, GPIO.HIGH)
        time.sleep(half)

GPIO.setwarnings(False)
GPIO.setmode(GPIO.BCM)
GPIO.setup(PIN, GPIO.OUT, initial=GPIO.HIGH)
for hz, dur in TUNE:
    tone(hz, dur)
GPIO.cleanup()
EOF
chmod 755 /usr/local/sbin/openastro-beep

cat > /etc/systemd/system/openastro-beep.service <<'EOF'
[Unit]
Description=OpenAstro: boot-ready jingle on the ASIAIR Plus buzzer
After=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/openastro-beep

[Install]
WantedBy=multi-user.target
EOF
systemctl enable openastro-beep.service >/dev/null 2>&1

# ============================================================
# WiFi access point (NetworkManager)
# ============================================================
# The AP is an NM keyfile connection with mode=ap and ipv4.method=shared -
# NM's internal dnsmasq serves DHCP/DNS and sets up NAT to whatever uplink
# exists. AlpacaBridge's WiFi manager drives this same NM setup over D-Bus
# (polkit rule ships in the AlpacaBridge .deb).
log "Configuring WiFi access point..."

# Dedicated AP interface: the hotspot lives on ap0 so wlan0 stays free for
# client mode - joining a network from the AlpacaBridge WiFi card no longer
# drops the hotspot. ap0 must exist before NM starts; a oneshot creates it
# from phy0 each boot (virtual interfaces don't persist). Its MAC is wlan0's
# with the locally-administered bit set, so the two interfaces never collide.
cat > /usr/local/sbin/openastro-ap-iface <<'EOF'
#!/bin/bash
set -euo pipefail
for _ in $(seq 1 60); do
    [ -d /sys/class/ieee80211/phy0 ] && break
    sleep 1
done
[ -d /sys/class/ieee80211/phy0 ] || exit 0
ip link show ap0 >/dev/null 2>&1 && exit 0
iw phy phy0 interface add ap0 type __ap
if [ -r /sys/class/net/wlan0/address ]; then
    mac=$(cat /sys/class/net/wlan0/address)
    first=$(( (0x${mac%%:*} | 0x02) & 0xfe ))
    ip link set ap0 address "$(printf '%02x' "$first")${mac#??}" || true
fi
EOF
chmod 755 /usr/local/sbin/openastro-ap-iface

cat > /etc/systemd/system/openastro-ap-iface.service <<'EOF'
[Unit]
Description=OpenAstro: create dedicated AP interface (ap0)
Before=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/openastro-ap-iface

[Install]
WantedBy=multi-user.target
EOF
mkdir -p /etc/systemd/system/NetworkManager.service.d
cat > /etc/systemd/system/NetworkManager.service.d/openastro-ap-iface.conf <<'EOF'
[Unit]
After=openastro-ap-iface.service
Wants=openastro-ap-iface.service
EOF
systemctl enable openastro-ap-iface.service >/dev/null 2>&1

# autoconnect keeps the hotspot up from boot: the board is always reachable
# at ${AP_IP} via its own AP even when the user can't log in over their LAN.
AP_UUID=$(cat /proc/sys/kernel/random/uuid)
mkdir -p /etc/NetworkManager/system-connections
cat > /etc/NetworkManager/system-connections/OpenAstro-AP.nmconnection <<EOF
[connection]
id=OpenAstro-AP
uuid=${AP_UUID}
type=wifi
interface-name=ap0
autoconnect=true
# Below default (0): saved client networks are tried first; the hotspot is
# the fallback when none of them connects.
autoconnect-priority=-10
# Retry forever: with the default (4 attempts) a slow first boot can
# permanently block the AP until reboot.
autoconnect-retries=0

[wifi]
mode=ap
ssid=${AP_SSID}
band=${AP_BAND}
channel=${AP_CHANNEL}

[wifi-security]
key-mgmt=wpa-psk
psk=${AP_PASSPHRASE}

[ipv4]
method=shared
addresses=${AP_IP}/24

[ipv6]
method=disabled
EOF
chmod 600 /etc/NetworkManager/system-connections/OpenAstro-AP.nmconnection

# Keyfile was just (re)written with the generic SSID - let the suffixer run
# again on next boot.
rm -f /var/lib/openastro/ssid-set

# Per-board SSID: suffix with the last 4 hex digits of the wlan0 MAC (unique
# and burned into the SoC/radio). Runs once on first boot, before NM, so
# multiple boards at a star party don't collide on the same SSID.
cat > /usr/local/sbin/openastro-ssid <<'EOF'
#!/bin/bash
set -euo pipefail
for _ in $(seq 1 60); do
    [ -r /sys/class/net/wlan0/address ] && break
    sleep 1
done
mac=$(tr -d ':' < /sys/class/net/wlan0/address)
suffix=$(echo "${mac: -4}" | tr 'a-f' 'A-F')
[ ${#suffix} -eq 4 ] || exit 0   # no/odd MAC: keep the generic SSID
sed -i "s/^ssid=\(.*\)/ssid=\1-${suffix}/" \
    /etc/NetworkManager/system-connections/OpenAstro-AP.nmconnection
EOF
chmod 755 /usr/local/sbin/openastro-ssid

cat > /etc/systemd/system/openastro-ssid.service <<'EOF'
[Unit]
Description=OpenAstro: per-board AP SSID from wlan0 MAC
Before=NetworkManager.service
ConditionPathExists=!/var/lib/openastro/ssid-set

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/openastro-ssid
ExecStartPost=/bin/mkdir -p /var/lib/openastro
ExecStartPost=/bin/touch /var/lib/openastro/ssid-set

[Install]
WantedBy=multi-user.target
EOF
mkdir -p /etc/systemd/system/NetworkManager.service.d
cat > /etc/systemd/system/NetworkManager.service.d/openastro-ssid.conf <<'EOF'
[Unit]
After=openastro-ssid.service
Wants=openastro-ssid.service
EOF
systemctl enable openastro-ssid.service >/dev/null 2>&1

# Regdom for the AP. On Raspberry Pi OS WiFi is soft-blocked by rfkill
# until a country is set - set it every way that sticks in a chroot.
iw reg set "${AP_COUNTRY}" 2>/dev/null || true
raspi-config nonint do_wifi_country "${AP_COUNTRY}" >/dev/null 2>&1 || true
cat > /etc/modprobe.d/openastro-regdom.conf <<EOF
options cfg80211 ieee80211_regdom=${AP_COUNTRY}
EOF
# Clear any persisted rfkill soft-block so the AP can start on first boot.
rm -f /var/lib/systemd/rfkill/*wlan* 2>/dev/null || true

# WiFi behavior for an always-on hotspot: no powersave (an AP that naps
# drops clients serving a mount all night) and no scan MAC randomization
# (keeps the radio identity stable/predictable).
cat > /etc/NetworkManager/conf.d/20-openastro-wifi.conf <<'EOF'
[connection]
wifi.powersave=2

[device]
wifi.scan-rand-mac-address=no
EOF

systemctl enable NetworkManager >/dev/null 2>&1

log "WiFi AP configured (SSID: ${AP_SSID}, band ${AP_BAND} ch${AP_CHANNEL}, ${AP_IP})."

# ============================================================
# First-boot reliability
# ============================================================
# The image build strips SSH host keys (unique per device). Regenerate them
# before sshd starts - otherwise ssh.service fails on first boot
# ("Connection refused" until a reboot).
cat > /etc/systemd/system/openastro-sshkeys.service <<'EOF'
[Unit]
Description=OpenAstro: generate SSH host keys on first boot
Before=ssh.service
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A

[Install]
WantedBy=multi-user.target
EOF
mkdir -p /etc/systemd/system/ssh.service.d
cat > /etc/systemd/system/ssh.service.d/openastro-after-keys.conf <<'EOF'
[Unit]
After=openastro-sshkeys.service
Wants=openastro-sshkeys.service
EOF
systemctl enable openastro-sshkeys.service >/dev/null 2>&1
systemctl enable ssh >/dev/null 2>&1

# Persistent journal, so first-boot failures survive a power cycle and can
# actually be debugged.
install -d -m 2755 -g systemd-journal /var/log/journal

# ============================================================
# Astro-device permissions (present from first boot, so device
# access never depends on install order of AlpacaBridge)
# ============================================================
# ZWO EAF/EFW/CAA are USB HID devices; without this, /dev/hidraw* is
# root-only until AlpacaBridge's own udev rules land AND the device is
# replugged. Shipping the rule in the image removes that ordering trap.
cat > /etc/udev/rules.d/70-openastro-zwo-hid.rules <<'EOF'
# ZWO HID accessories (EAF focuser, EFW/EFWmini filter wheels, CAA rotator)
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="03c3", GROUP="users", MODE="0666"
KERNEL=="hiddev*", ATTRS{idVendor}=="03c3", GROUP="users", MODE="0666"
EOF

# ============================================================
# System identity (turnkey - no first-boot wizard)
# ============================================================
log "Setting system identity..."
OA_HOSTNAME="${OPENASTRO_HOSTNAME:-openastro}"
OA_USER="${OPENASTRO_USER:-astro}"
OA_PASS="${OPENASTRO_PASS:-astro}"
echo "$OA_HOSTNAME" > /etc/hostname
if grep -q '^127.0.1.1' /etc/hosts; then sed -i "s/^127.0.1.1.*/127.0.1.1\t$OA_HOSTNAME/" /etc/hosts
else echo -e "127.0.1.1\t$OA_HOSTNAME" >> /etc/hosts; fi
OA_GROUPS=""
for g in sudo dialout plugdev audio video netdev gpio i2c spi; do
    getent group "$g" >/dev/null && OA_GROUPS="${OA_GROUPS:+$OA_GROUPS,}$g"
done
id "$OA_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash -G "$OA_GROUPS" "$OA_USER"
echo "${OA_USER}:${OA_PASS}" | chpasswd
# Disable RPi OS's interactive first-boot user wizard (credentials are baked
# in); it otherwise blocks boot waiting for console input on Lite.
systemctl disable userconfig.service 2>/dev/null || true
rm -f /etc/ssh/sshd_config.d/rename_user.conf 2>/dev/null || true

# ============================================================
# AlpacaBridge (preinstalled - the whole point of the appliance;
# a dark site has no internet to apt install from)
# ============================================================
# Installs the latest release from the repo.
INSTALL_ALPACABRIDGE="${INSTALL_ALPACABRIDGE:-yes}"
if [ "$INSTALL_ALPACABRIDGE" = yes ]; then
log "Installing AlpacaBridge from apt.openastro.net..."
curl -fsSL https://apt.openastro.net/repo/openastro-archive-keyring.gpg \
    | gpg --dearmor --yes -o /usr/share/keyrings/openastro-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/openastro-archive-keyring.gpg] https://apt.openastro.net trixie main" \
    > /etc/apt/sources.list.d/openastro.list
apt-get update -qq
apt-get install -y -qq alpacabridge >/dev/null
fi

log "OpenAstro OS layer complete (ASIAIR Plus power/USB + WiFi AP + identity + AlpacaBridge)."
