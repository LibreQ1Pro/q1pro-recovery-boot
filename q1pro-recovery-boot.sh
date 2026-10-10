#!/bin/sh
# Patches the boot sequence of the QIDI Q1 Pro stock firmware: USB first,
# then the eMMC.  Renames /boot/extlinux/extlinux.conf to extlinux-emmc.conf,
# adds boot.cmd and boot.scr.  install requires QIDI's U-Boot
# (--bypass-check skips that).
#
# Usage: q1pro-recovery-boot.sh {install|uninstall|status} [--boot DIR]
#        [--bypass-check]
set -eu

BOOT=/boot
BYPASS=false

# QIDI's loader: sector, size, sha256 of idbloader, uboot.img, trust
QIDI_LOADER="
64 102916 d8398839d4959c9b5124770edc6e50e3350c0e20f3493e3593aa5c5d53b09177
16384 4194304 2a76be4f27772399540d44461d75c23a6ec09e0f81becb1a7ae1a670a8440f1e
24576 4194304 5cf001e9ac2a57895b47060342f6ebc3fd04bad3bf7fb41ac10731c5b604f647
"

die() {
	echo "error: $*" >&2
	exit 1
}

usage() {
	echo "usage: $0 {install|uninstall|status} [--boot DIR] [--bypass-check]" >&2
	exit 2
}

boot_disk() {
	src=$(findmnt -n -o SOURCE --target "$BOOT" 2>/dev/null) || return 0
	[ -b "$src" ] || return 0
	pk=$(lsblk -n -o PKNAME "$src" 2>/dev/null | head -n 1)
	if [ -n "$pk" ] && [ -b "/dev/$pk" ]; then
		echo "/dev/$pk"
	fi
}

# qidi, other or unknown (disk not found or not readable)
uboot_kind() {
	disk=$(boot_disk)
	if [ -z "$disk" ] || [ ! -r "$disk" ]; then
		echo unknown
		return
	fi
	result=qidi
	for entry in $(echo "$QIDI_LOADER" | tr ' ' ':'); do
		sector=${entry%%:*}
		rest=${entry#*:}
		size=${rest%%:*}
		sum=${rest#*:}
		got=$(dd if="$disk" bs=512 skip="$sector" \
		      count=$(( (size + 511) / 512 )) 2>/dev/null |
		      head -c "$size" | sha256sum | cut -d ' ' -f 1)
		[ "$got" = "$sum" ] || result=other
	done
	echo "$result"
}

check_uboot() {
	if $BYPASS; then
		return 0
	fi
	uk=$(uboot_kind)
	[ "$uk" != unknown ] ||
		die "cannot read the disk of $BOOT to check its U-Boot (run as root), see --bypass-check"
	[ "$uk" = qidi ] ||
		die "U-Boot on $(boot_disk) is not QIDI's, see --bypass-check"
}

installed() {
	[ -f "$BOOT/extlinux/extlinux-emmc.conf" ]
}

# installed, not installed or unknown (neither layout)
state() {
	if installed && [ ! -e "$BOOT/extlinux/extlinux.conf" ]; then
		echo installed
	elif [ -f "$BOOT/extlinux/extlinux.conf" ] && ! installed &&
	     [ ! -e "$BOOT/boot.scr" ]; then
		echo "not installed"
	else
		echo unknown
	fi
}

write_cmd() {
	cat > "$1" <<'QIDI_RECOVERY_EOF'
# Boot USB if it has extlinux/extlinux.conf or boot.scr, else the eMMC
# (extlinux/extlinux-emmc.conf).  QIDI's U-Boot 2021.07 only.
# mkimage -C none -A arm64 -T script -d boot.cmd boot.scr

setenv emmc_devtype ${devtype}
setenv emmc_devnum ${devnum}
setenv emmc_part ${distro_bootpart}
setenv emmc_prefix ${prefix}

# LEDs: RK805 (I2C1, 0x18) register 0x52 = ${led}.  bit0: 0 blue, 1 green;
# bit1: 0 yellow on.  No i2c command, so the I2C controller is driven
# directly: START, TX 0x30 0x52 ${led}, STOP.
setenv led_set 'mw.l 0xff16001c 0x7f; mw.l 0xff160000 0x9; sleep 0.01; mw.l 0xff16001c 0x7f; mw.l 0xff160100 0x00${led}5230; mw.l 0xff160000 0x1; mw.l 0xff160010 3; sleep 0.01; mw.l 0xff16001c 0x7f; mw.l 0xff160000 0x11; sleep 0.01; mw.l 0xff16001c 0x7f; mw.l 0xff160000 0'

# Alternate led_a/led_b (led_t s each) once per word of led_count, then led_end
setenv led_blink 'for led_i in ${led_count}; do setenv led ${led_a}; run led_set; sleep ${led_t}; setenv led ${led_b}; run led_set; sleep ${led_t}; done; setenv led ${led_end}; run led_set'

# USB: blue + yellow blinking; eMMC: green + yellow blinking; both end in
# the power-on state.  Error: fast blue/green, ends blue.
setenv led_usb 'setenv led_a 00; setenv led_b 02; setenv led_t 0.2; setenv led_count "1 2 3"; setenv led_end 00; run led_blink'
setenv led_emmc 'setenv led_a 03; setenv led_b 01; setenv led_t 0.2; setenv led_count "1 2 3"; setenv led_end 00; run led_blink'
setenv led_error 'setenv led_a 00; setenv led_b 01; setenv led_t 0.08; setenv led_count "1 2 3 4 5 6 7 8 9 10 11 12"; setenv led_end 02; run led_blink'

# Ring: U-Boot is up.  0.1 s per step (led_set takes 0.03 s)
for led_r in 01 03 02 00; do
	sleep 0.07
	setenv led ${led_r}
	run led_set
done

# Power the USB hub (vcc_host1_5v, GPIO0_A2), U-Boot leaves it off.  GPIO0
# as Linux sets it: A2 and D6 (vcc_sd) high outputs.
mw.l 0xff210000 0x40000004
mw.l 0xff210004 0x40000004
sleep 1

# A USB boot.scr gets devtype/devnum/distro_bootpart/prefix pointing at it
# (setenv overrides distro boot's hush variables) and the mkspi DTB if it
# has one (this U-Boot defaults to roc-cc).
usb start
for usb_n in 0 1 2 3; do
	for usb_p in 1 2; do
		for usb_pre in / /boot/; do
			if test -e usb ${usb_n}:${usb_p} ${usb_pre}extlinux/extlinux.conf; then
				echo "Booting USB ${usb_n}:${usb_p} ${usb_pre}extlinux/extlinux.conf"
				run led_usb
				sysboot usb ${usb_n}:${usb_p} any ${pxefile_addr_r} ${usb_pre}extlinux/extlinux.conf
				echo "USB boot failed"
				run led_error
			fi
			if test -e usb ${usb_n}:${usb_p} ${usb_pre}boot.scr; then
				echo "Booting USB ${usb_n}:${usb_p} ${usb_pre}boot.scr"
				setenv devtype usb
				setenv devnum ${usb_n}
				setenv distro_bootpart ${usb_p}
				setenv prefix ${usb_pre}
				setenv fdtfile rockchip/rk3328-roc-cc.dtb
				if test -e usb ${usb_n}:${usb_p} ${usb_pre}dtb/rockchip/rk3328-mkspi.dtb; then
					setenv fdtfile rockchip/rk3328-mkspi.dtb
				fi
				run led_usb
				load usb ${usb_n}:${usb_p} ${pxefile_addr_r} ${usb_pre}boot.scr
				source ${pxefile_addr_r}
				echo "USB boot failed"
				run led_error
			fi
		done
	done
done

# Back to the distro boot variables
setenv devtype
setenv devnum
setenv distro_bootpart
setenv prefix
setenv fdtfile rockchip/rk3328-roc-cc.dtb

echo "No system on USB, booting eMMC"
run led_emmc
sysboot ${emmc_devtype} ${emmc_devnum}:${emmc_part} any ${pxefile_addr_r} ${emmc_prefix}extlinux/extlinux-emmc.conf
echo "eMMC boot failed"
run led_error
QIDI_RECOVERY_EOF
}

do_install() {
	command -v mkimage >/dev/null ||
		die "mkimage not found (apt install u-boot-tools)"
	! installed || die "already installed"
	[ -f "$BOOT/extlinux/extlinux.conf" ] ||
		die "$BOOT/extlinux/extlinux.conf not found"
	[ ! -e "$BOOT/boot.scr" ] || die "$BOOT/boot.scr exists"
	[ ! -e "$BOOT/boot.cmd" ] || die "$BOOT/boot.cmd exists"
	# boot.scr first: until extlinux.conf is renamed U-Boot still uses it
	write_cmd "$BOOT/boot.cmd.new"
	if ! mkimage -C none -A arm64 -T script -n q1pro-recovery-boot \
		-d "$BOOT/boot.cmd.new" "$BOOT/boot.scr.new" >/dev/null; then
		rm -f "$BOOT/boot.cmd.new" "$BOOT/boot.scr.new"
		die "mkimage failed"
	fi
	mv "$BOOT/boot.cmd.new" "$BOOT/boot.cmd"
	mv "$BOOT/boot.scr.new" "$BOOT/boot.scr"
	sync
	mv "$BOOT/extlinux/extlinux.conf" "$BOOT/extlinux/extlinux-emmc.conf"
	sync
	echo "installed in $BOOT"
}

do_uninstall() {
	installed || die "not installed"
	[ ! -e "$BOOT/extlinux/extlinux.conf" ] ||
		die "$BOOT/extlinux/extlinux.conf exists"
	# boot.scr is ours if its uImage name (offset 32, 32 bytes) is ours and
	# it was built from boot.cmd (data after the header and length table)
	if [ -e "$BOOT/boot.scr" ]; then
		name=$(dd if="$BOOT/boot.scr" bs=1 skip=32 count=32 2>/dev/null |
		       tr -d '\000')
		[ "$name" = q1pro-recovery-boot ] ||
			die "$BOOT/boot.scr is not ours (uImage name '$name')"
		tail -c +73 "$BOOT/boot.scr" | cmp -s - "$BOOT/boot.cmd" ||
			die "$BOOT/boot.scr is not built from $BOOT/boot.cmd"
	fi
	# extlinux.conf first: U-Boot prefers it to boot.scr
	mv "$BOOT/extlinux/extlinux-emmc.conf" "$BOOT/extlinux/extlinux.conf"
	sync
	rm -f "$BOOT/boot.scr" "$BOOT/boot.cmd"
	sync
	echo "uninstalled from $BOOT"
}

[ $# -ge 1 ] || usage
cmd=$1
shift
while [ $# -gt 0 ]; do
	case "$1" in
	--boot)
		[ $# -ge 2 ] || usage
		BOOT=$2
		shift 2
		;;
	--bypass-check)
		BYPASS=true
		shift
		;;
	*)
		usage
		;;
	esac
done

[ -d "$BOOT" ] || die "$BOOT is not a directory"
case "$cmd" in
status)
	echo "$BOOT: $(state), U-Boot: $(uboot_kind)"
	;;
install)
	[ -w "$BOOT" ] || die "$BOOT is not writable (run as root)"
	check_uboot
	do_install
	;;
uninstall)
	[ -w "$BOOT" ] || die "$BOOT is not writable (run as root)"
	do_uninstall
	;;
*)
	usage
	;;
esac
