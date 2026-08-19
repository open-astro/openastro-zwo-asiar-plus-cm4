# Flashing the ASIAIR Plus (CM4)

The ASIAIR Plus's OS lives on the 32 GB eMMC on the Raspberry Pi CM4. To
read or write it, the board is put in USB device-boot mode and
[rpiboot](https://github.com/raspberrypi/usbboot) (Raspberry Pi usbboot)
exposes the eMMC to your computer as a normal USB disk. The scripts here
wrap the whole workflow: install rpiboot, **back up the stock ZWO ASIAIR
OS**, flash the OpenAstro image, and restore stock later if you want.

> ⚠️ **CM4 model only.** These scripts are for the first-generation,
> Raspberry Pi CM4-based ASIAIR Plus. They will **not** work on the
> Rockchip (RK3568) ASIAIR Plus revisions.

> ⚠️ **Back up first.** The stock ZWO ASIAIR OS is not publicly
> downloadable. The `backup` command's output file is the *only* way back to
> stock - run it once before your first flash and keep the file somewhere
> safe.

## Scripts

| OS | Script |
|---|---|
| Linux, macOS | `openastro-flash.sh` |
| Windows | `openastro-flash.ps1` (elevated PowerShell) |

## Usage

Just run the script with no arguments and pick from the menu:

```bash
# Linux / macOS
./openastro-flash.sh
```

```powershell
# Windows (Administrator PowerShell)
.\openastro-flash.ps1
```

```
  1) Backup  - save the stock ZWO ASIAIR OS from the eMMC (do this first!)
  2) Flash   - write the OpenAstro image to the eMMC
  3) Restore - write a stock backup back to the eMMC
```

Everything else is automatic:

- **rpiboot** is installed on first use (you're asked before it installs).
- **Flash** downloads the latest OpenAstro release image (with checksum
  verification) into `images/` if it isn't there already, and offers to make
  a stock backup first if none exists.
- **Restore** picks up the newest backup in `images/` automatically.

For scripting, the menu choices also work as subcommands
(`backup [out]`, `flash [image]`, `restore [backup]`).

Each backup/flash/restore run walks you through the same steps:

1. **Enter USB device-boot mode** - with the ASIAIR Plus unplugged, open
   the case and short the two nRPIBOOT boot pads on the carrier board with
   a jumper wire (keep them shorted). Connect a **USB-A (computer) to
   USB-C (ASIAIR Plus)** data cable, then connect **12V DC power** - unlike
   most CM4 boards, the ASIAIR Plus does **not** power up from the USB
   cable alone; it needs 12V power to turn on. The script pauses here and
   waits for you to press Enter, then rpiboot pushes the mass-storage
   gadget to the CM4 and the eMMC appears as a USB disk.
2. **Device safety checks** - the script identifies the eMMC by the
   mass-storage gadget's USB identity (`RPi-MSD`), falling back to the disk
   that *newly appeared* (never guessed), refuses anything that isn't
   ~32 GB, and makes you re-type the device before touching it. If the
   gadget is already connected from a previous run, it's picked up directly
   without re-running rpiboot.
3. **Read or write, then verify** - progress throughout; backups get a
   `.sha256` checksum file, and every flash/restore write is verified by
   reading the written data back off the eMMC and comparing SHA-256
   checksums before declaring success.


## Notes per OS

- **Linux**: rpiboot is built from source (needs `libusb-1.0-0-dev`; the
  script installs deps via apt). Backups are `.img.xz`.
- **macOS**: rpiboot comes from Homebrew (source-build fallback included).
  Uses `/dev/rdiskN` raw nodes for speed. Backups are `.img.xz`.
- **Windows**: rpiboot comes from the official installer (includes the boot
  driver) in the usbboot releases. Backups are `.img.gz` (native .NET gzip;
  no xz on stock Windows). Flashing the released `.img.xz` needs
  [7-Zip](https://www.7-zip.org) installed - the script finds it and
  decompresses automatically (or use
  [Raspberry Pi Imager](https://www.raspberrypi.com/software/) pointed at
  the disk rpiboot exposes).

## Restoring stock ZWO ASIAIR

`restore` is just `flash` with your backup file: same boot-mode dance, same
safety checks, writes the saved image back, and the unit boots the original
ASIAIR firmware as if nothing happened.
