# ASIAIR Plus (CM4) hardware notes

Placeholder for a hardware/software inventory captured live from a running
stock ASIAIR Plus (CM4), with its original configs and scripts - the
counterpart of `hardware/stellavita-cm4-32g/` in
[openastro-touptek-stellavita](https://github.com/open-astro/openastro-touptek-stellavita).

Known so far (per the
[install guide](https://www.openastro.net/docs/sbc-install/zwo-asiair-plus-cm4)):

- Raspberry Pi CM4 with 32 GB eMMC.
- 12V DC power outputs switched by GPIO 12, 13, 26, 18
  (`gpio=12,13,26,18=op,dh,pu` in `config.txt`).
- USB 3.0 ports behind a Renesas uPD72020x xHCI controller
  (`xhci-pci-renesas`), needing `renesas_usb_fw.mem` firmware.
- USB device-boot mode: short the nRPIBOOT boot pads, USB-A to USB-C data
  cable, plus 12V DC power (the board does not power up from USB alone).
- Piezo buzzer on BCM GPIO 19, same as the ASIAIR Pro (verified audibly on
  live hardware with the OpenAstro jingle).
