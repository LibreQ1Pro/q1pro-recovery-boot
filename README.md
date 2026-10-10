# QIDI Q1 Pro: USB recovery boot for the stock firmware

[Русский](README.ru.md)

This script lets a QIDI Q1 Pro with the stock firmware boot from a USB flash
drive, so that you can start a recovery system or another firmware without
taking the eMMC out of the printer. It patches the boot sequence: when a flash
drive with a system is plugged in, the printer boots from it; without one it
boots from the eMMC as before.

Nothing is flashed. The installer only changes files on the BOOT partition of
the eMMC (`/boot`), and `uninstall` puts them back.

## What you need

* A QIDI Q1 Pro with the stock QIDI firmware. The installer checks that the
  eMMC has QIDI's bootloader and refuses to install otherwise.
* SSH access to the printer.
* Recommended: [Makerbase EMMC-ADAPTER](https://makerbase3d.com/product/makerbase-emmc-adapter-v2-usb-3-0-reader-for-mks-emmc-module-micro-sd-tf-card-mks-pi-mks-skipr/), to connect the eMMC to a
  computer [if the printer does not boot](#if-the-printer-does-not-boot).
* Optional, to boot something from USB: a flash drive with a system for this
  board, for example [Armbian for `mkspi`](https://armbian.com/boards/mkspi).
  The drive must have `extlinux/extlinux.conf` or `boot.scr` in `/` or
  `/boot/` of its first or second partition. Its root partition must have its
  own UUID, so a copy of the eMMC will not do.

> Use at your own risk, see the [disclaimer](#disclaimer).

## Install

Log in to the printer over SSH (user `mks`, default password `makerbase`),
download the script and run it as root:

```sh
curl -fLO https://raw.githubusercontent.com/LibreQ1Pro/q1pro-recovery-boot/main/q1pro-recovery-boot.sh
sudo sh q1pro-recovery-boot.sh install
```

Without internet on the printer, use a USB flash drive:

1. Download `q1pro-recovery-boot.sh` on a computer and copy it to a flash
   drive (FAT32 or exFAT).
2. Plug the flash drive into the printer. The stock firmware mounts it as a
   folder in `~/gcode_files`.
3. Find the script there:

   ```sh
   ls ~/gcode_files/*/q1pro-recovery-boot.sh
   ```

   It prints the path, for example
   `/home/mks/gcode_files/sda1/q1pro-recovery-boot.sh`.
4. Run the script by that path:

   ```sh
   sudo sh /home/mks/gcode_files/sda1/q1pro-recovery-boot.sh install
   ```

Check the result:

```sh
sh q1pro-recovery-boot.sh status
```

It prints `/boot: installed, U-Boot: qidi`.

To go back to the stock boot:

```sh
sudo sh q1pro-recovery-boot.sh uninstall
```

## Booting from the flash drive

1. Turn the printer off.
2. Plug the flash drive into one of the two USB 2.0 ports of the mainboard
   (marked 1). The USB 3.0 port above them does not work at this stage of the
   boot.
3. Turn the printer on.

![USB ports](images/mainboard-usb.jpg)

Booting from the flash drive takes a minute or two: the stock bootloader reads
USB slowly. Without a flash drive the boot takes as long as before.

## LED signals

The three LEDs on the mainboard show what the bootloader does.

![LED signals](images/led-signals.svg)

| Stage | LEDs |
|---|---|
| Power on | blue and yellow |
| Bootloader started | all LEDs blink quickly once |
| Booting from the eMMC | green, yellow blinks 3 times |
| Booting from the flash drive | blue, yellow blinks 3 times |
| Boot failed | blue and green flash fast, then only blue stays on |

After the eMMC and flash drive signals the LEDs go back to blue and yellow.
If no flash drive with a system is found, the printer boots from the eMMC.
Once Linux runs, the LEDs are up to the system: the stock firmware blinks
them, a system on the flash drive may leave them blue and yellow.

## If the printer does not boot

Take the eMMC out, connect it to a computer and on its BOOT partition:

1. delete `boot.scr` and `boot.cmd`;
2. rename `extlinux/extlinux-emmc.conf` to `extlinux/extlinux.conf`.

That is the stock state again.

---

## Details

### What the installer changes

| File in `/boot` | Change |
|---|---|
| `extlinux/extlinux.conf` | renamed to `extlinux/extlinux-emmc.conf` |
| `boot.cmd` | added, the source of the boot script |
| `boot.scr` | added, built from `boot.cmd` with `mkimage` on the printer |

The bootloader reads `extlinux/extlinux.conf` before `boot.scr`, so the file
is renamed. The installer builds `boot.scr` first and renames the file last.
`uninstall` restores the file first and deletes the script last. If either one
stops halfway, the printer still boots the stock way.

### Commands

```
q1pro-recovery-boot.sh {install|uninstall|status} [--boot DIR] [--bypass-check]
```

* `--boot DIR`: work on another directory instead of `/boot`.
* `--bypass-check`: skip the bootloader check. The boot script is made for
  QIDI's bootloader (its memory addresses, USB power and LED wiring), so this
  is only for tests.

The bootloader is recognized by the SHA-256 of its three parts on the eMMC:
`idbloader` (sector 64), `uboot.img` (sector 16384) and `trust`
(sector 24576), taken from an untouched Q1 Pro.

### How the boot script works

The stock bootloader is U-Boot 2021.07 from QIDI's Armbian build. The script:

1. drives the LEDs. They are on the RK805 power chip (register `0x52`), and
   this U-Boot has no command for it, so the script talks to the I2C
   controller directly;
2. turns on the power of the internal USB hub, which this U-Boot leaves off;
3. looks for a system on the flash drive and boots it;
4. otherwise boots the eMMC with `extlinux/extlinux-emmc.conf`.

The USB 3.0 port is on a USB controller this U-Boot has no driver for. The hub
runs at USB 1.1 speed in this U-Boot, so the flash drive boot is slow.

### Disclaimer

The script is provided as is, without any warranty. You install it at your
own risk and you alone are responsible for the result. The authors are not
liable for any damage or loss: a printer that does not boot, a printer stuck
until you get a way to connect the eMMC to a computer, downtime of the printer,
interrupted work or business, lost income or anything else.

### Copyright

The script and `images/led-signals.svg`: MIT, see [LICENSE](LICENSE).

The board picture is QIDI's product photo of the mainboard
(https://qidi3d.com/products/q1pro-motherboard) with our marks.
