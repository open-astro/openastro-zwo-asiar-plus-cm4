# OpenAstro for ZWO ASIAIR Plus (CM4)

<img src="https://www.openastro.net/wp-content/uploads/2026/04/OpenAstro_logo.png" alt="OpenAstro logo" width="420">

OpenAstro OS for the **ZWO ASIAIR Plus** (first-generation, Raspberry Pi
CM4 based): a
[Raspberry Pi OS Lite](https://www.raspberrypi.com/software/operating-systems/)
(arm64, no GUI, Debian 13 "Trixie") based image with the ASIAIR Plus's
power and USB hardware enabled, a WiFi access point, and everything ready
for [AlpacaBridge](https://github.com/open-astro/AlpacaBridge).

> ⚠️ **CM4 model only.** This image is for the first-generation, Raspberry
> Pi CM4-based ASIAIR Plus. It will **not** work on the Rockchip (RK3568)
> ASIAIR Plus revisions.

Everything from the
[ASIAIR Plus (CM4) install guide](https://www.openastro.net/docs/sbc-install/zwo-asiair-plus-cm4)
is baked into the image:

- **12V power outputs** - GPIO 12, 13, 26, 18 driven high at boot via
  `config.txt`, so the DC outputs are live from power-on.
- **USB ports** - the Renesas uPD72020x xHCI firmware
  (`renesas_usb_fw.mem`) is preinstalled and built into the initramfs, so
  the USB 3.0 ports behind the ASIAIR's Renesas xhci-pci controller work
  out of the box.
- **Buzzer** - the OpenAstro jingle plays on the piezo (GPIO 19, same as
  the ASIAIR Pro) once the board is up, so you know it's ready without a
  screen (`/usr/local/sbin/openastro-beep`).

## Supported hardware

| Device | Kernel | Status |
|--------|--------|--------|
| ZWO ASIAIR Plus (Pi CM4) | Raspberry Pi OS stock | ✅ Tested and working |

> **ZWO EAF/EFW:** the stock Raspberry Pi OS kernel ships with HIDRAW
> enabled, and the image bakes in a udev rule granting device access, so ZWO
> HID accessories should work out of the box.

## Install

The ASIAIR Plus's OS lives on the CM4's 32 GB eMMC, reached over USB with
[rpiboot](https://github.com/raspberrypi/usbboot). The
[`flash/`](flash/) scripts (Linux, macOS, Windows) handle the whole
workflow: install rpiboot, **back up the stock ZWO ASIAIR OS** (your only
way back to stock - do this first), flash the OpenAstro image, and restore
the stock backup later if you want.

To enter USB device-boot mode: short the two nRPIBOOT boot pads on the
carrier board with a jumper wire, connect a USB-A (computer) to USB-C
(ASIAIR) data cable, and connect **12V DC power** - the ASIAIR Plus does
not power up from the USB cable alone. The flash script walks you through it.

```bash
cd flash
./openastro-flash.sh
```

```
  1) Backup  - save the stock ZWO ASIAIR OS from the eMMC (do this first!)
  2) Flash   - write the OpenAstro image to the eMMC
  3) Restore - write a stock backup back to the eMMC
```

Everything else is automatic: rpiboot installs on first use, and Flash
downloads the latest release image if it isn't already in `images/`.
(Windows: `flash\openastro-flash.ps1` in an Administrator PowerShell, same
menu - see [`flash/README.md`](flash/README.md).)

Then power on. The 12V outputs and USB ports come up with the board.

## First boot defaults

| Setting | Value |
|---------|-------|
| Hostname | `openastro` |
| Login | `astro` / `astro` - **change immediately:** `passwd` |
| WiFi AP | `OpenAstro-XXXX` (2.4 GHz, ch 6), password `12345678` |
| AP address | `172.24.1.1` (DHCP for clients) |
| Ethernet | DHCP |

`XXXX` is the last 4 hex digits of the board's WiFi MAC address (e.g.
`OpenAstro-915D`), applied automatically on first boot so multiple boards in
the same place each get a unique hotspot name.

Reach it over ethernet (`ssh astro@<ip>`) or by joining the `OpenAstro-XXXX`
WiFi. The access point starts automatically at every boot, so even if the
board can't be reached over your network you can always join its hotspot and
log in at `172.24.1.1`.

### Connect to your own network instead (optional)

All networking is managed by NetworkManager. The hotspot runs on a dedicated
virtual interface (`ap0`), concurrent with `wlan0` client mode, so joining
your own network - from AlpacaBridge's WiFi card in the web portal, or with
`nmcli` (`sudo nmcli dev wifi connect <SSID> password <pass>`) - does **not**
take down the hotspot. (One radio, one channel: while connected as a client
the hotspot follows the client network's channel.) You can also just use the
ethernet port.

## AlpacaBridge

[AlpacaBridge](https://github.com/open-astro/AlpacaBridge) is **preinstalled**
from the OpenAstro apt repository, so the device works at a dark site straight
from the flash - no internet required. When the device does have internet, it
stays current with `sudo apt update && sudo apt upgrade`.

## Build the image yourself

The release image is built from a stock Raspberry Pi OS Lite (arm64) image
plus the OpenAstro layer. On an **aarch64** host (an arm64 Debian box, or a
Pi itself - it's a native chroot, no emulation):

```bash
# 1. grab the latest Raspberry Pi OS Lite arm64 image
wget https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2026-06-19/2026-06-18-raspios-trixie-arm64-lite.img.xz

# 2. bake in the OpenAstro layer and repack
sudo apt install parted e2fsprogs dosfstools
sudo build/build-openastro-image.sh 2026-06-18-raspios-trixie-arm64-lite.img.xz images/openastro-zwo-asiair-plus-cm4.img.xz
```

- [`build/build-openastro-image.sh`](build/build-openastro-image.sh) - customizes
  the Raspberry Pi OS image in a chroot and produces a compressed, flashable
  `.img.xz`.
- [`openastro/openastro-setup.sh`](openastro/openastro-setup.sh) - the OpenAstro
  layer (ASIAIR Plus power/USB enablement, WiFi AP, baked-in credentials, ZWO
  udev rule). Idempotent; also runnable directly on a booted ASIAIR Plus.

## Sibling projects

- [openastro-touptek-stellavita](https://github.com/open-astro/openastro-touptek-stellavita)
  - same OpenAstro layer for the ToupTek StellaVita (Pi CM4).
- [openastro-raspberrypi](https://github.com/open-astro/openastro-raspberrypi)
  - same OpenAstro layer for the Raspberry Pi 3B+/4/5.
- [openastro-orangepi4pro](https://github.com/open-astro/openastro-orangepi4pro)
  - same OpenAstro layer for the Orange Pi 4 Pro (Allwinner A733).

## License

See [LICENSE.md](LICENSE.md).
