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
workflow: install rpiboot, **back up the stock ZWO ASIAIR OS**, flash the
OpenAstro image, and restore the stock backup later if you want.

> ⚠️ **Back up first.** The stock ZWO ASIAIR OS is not available for
> download anywhere - the backup the script makes is your *only* way back
> to stock. Keep the `images/asiair-stock-backup-*` file somewhere safe.

### 1. Get the scripts

Clone this repository (or use **Code → Download ZIP** on GitHub and
extract it):

```bash
git clone https://github.com/open-astro/openastro-zwo-asiar-plus-cm4.git
cd openastro-zwo-asiar-plus-cm4
```

### 2. Put the ASIAIR Plus in USB boot mode

<img src="docs/asiair-plus-boot-mode.webp" alt="ASIAIR Plus CM4 with the boot pads shorted by a paperclip, USB-C data cable, and 12V power connected" width="500">

1. Unplug the ASIAIR Plus (no power).
2. Open the case and short the two **nRPIBOOT boot pads** on the carrier
   board with a paperclip or jumper wire. Keep them shorted.
3. Connect a **USB-A (computer) to USB-C (ASIAIR Plus)** data cable - a
   charge-only cable won't work.
4. Connect **12V DC power**. Unlike most CM4 boards, the ASIAIR Plus does
   **not** power up from the USB cable alone.

The script pauses and walks you through this, so you can also start the
script first and follow its prompts.

### 3. Install rpiboot (macOS only)

On macOS, install rpiboot with [Homebrew](https://brew.sh) before running the
script (or let the script install it for you):

```bash
brew install rpiboot
```

### 4. Run the flash script

**Linux / macOS:**

```bash
cd flash
./openastro-flash.sh
```

**Windows:** open **PowerShell as Administrator** (Start menu → type
*PowerShell* → right-click → *Run as administrator*), change to the
repository folder, and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\flash\openastro-flash.ps1
```

(`-ExecutionPolicy Bypass` lets Windows run the script without changing any
system-wide settings.)

Both show the same menu:

```
  1) Backup  - save the stock ZWO ASIAIR OS from the eMMC (do this first!)
  2) Flash   - write the OpenAstro image to the eMMC
  3) Restore - write a stock backup back to the eMMC
```

Run **1) Backup** first, then **2) Flash**. Unplug and replug the USB
cable and power between runs (keep the pads shorted) so the board re-enters
boot mode - Flash also offers to make the backup for you if none exists.

Everything else is automatic: rpiboot installs on first use, Flash
downloads the latest release image (checksum-verified) if it isn't already
in `images/`, and every write is verified by reading it back off the eMMC.
Wait for **"Verification PASSED"**.

**Windows notes:**

- rpiboot comes from the official Raspberry Pi installer - accept its
  driver prompts. If the USB boot driver didn't install, the script
  installs it for you.
- The release image is `.xz`, which Windows can't open natively. The
  script uses the `xz.exe` that ships with
  [Git for Windows](https://git-scm.com/download/win), or
  [7-Zip](https://www.7-zip.org) - install either one if you have neither.
  The image is decompressed on the fly straight onto the eMMC; no extra
  disk space is needed.
- While the script runs it suppresses Windows' *"You need to format the
  disk"* popup. If one appears anyway, click **Cancel** - never Format.
  Windows just can't read the Linux partitions.

See [`flash/README.md`](flash/README.md) for more detail.

### 5. Boot OpenAstro

Disconnect USB, **remove the paperclip/jumper**, and power-cycle. The 12V
outputs and USB ports come up with the board, and the buzzer plays the
OpenAstro jingle when it's ready.

To go back to stock later, enter boot mode the same way and choose
**3) Restore**.

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
