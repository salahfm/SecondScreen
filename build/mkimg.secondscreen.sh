# SecondScreen image profile for Alpine mkimage.
# Turns the ISO into a tiny "wireless monitor" kiosk for old x86_64 laptops
# (built for: Intel Celeron N4000, UHD 600, Wireless-AC 9560).
#
# This file is sourced by mkimage.sh from ~/.mkimage/, so the
# profile_secondscreen / section_kernels functions register themselves.

profile_secondscreen() {
	profile_standard

	# Append the writable data partition (built by build/mkprofile.sh and
	# passed in the environment). xorriso marks it in both the MBR and the
	# GPT of the hybrid image, so the guest can mount it by label.
	# Type 0x0c = FAT32 LBA.
	if [ -n "${PERSIST_IMG:-}" ]; then
		iso_opts="$iso_opts -append_partition 3 0x0c $PERSIST_IMG -appended_part_as_gpt"
	fi

	title="SecondScreen"
	desc="Tiny kiosk OS that turns an old laptop into a wireless second monitor
		for a Windows PC. Boots straight into a fullscreen Moonlight stream.
		Runs entirely from RAM."
	image_name="secondscreen"
	profile_abbrev="ss"
	arch="x86_64"
	output_format="iso"
	hostname="secondscreen"
	apkovl="secondscreen.apkovl.sh"

	# Early CPU microcode update (Gemini Lake).
	boot_addons="intel-ucode"
	initrd_ucode="/boot/intel-ucode.img"

	# NOTE: every package listed here is baked into the ISO's boot
	# repository. The apkovl's /etc/apk/world must only reference packages
	# that exist in that repository, because Alpine's init installs world
	# from it at boot. Keep the two lists consistent.
	# (Firmware is NOT listed here: it only needs to exist in the modloop,
	# which section_kernels() below builds with its own package set. That
	# keeps ~90 MB of firmware out of the boot repository. In Alpine 3.20
	# there is no linux-firmware-iwlwifi split; the flat iwlwifi-*.ucode
	# files ship in the 'other' catch-all subpackage.)
	apks="$apks
		moonlight-qt
		xorg-server
		mesa-gl
		mesa-dri-gallium
		libva
		intel-media-driver
		libva-intel-driver
		libva-utils
		eudev
		wpa_supplicant
		iw
		wireless-regdb
		setxkbmap
		xkeyboard-config
		font-dejavu
		ca-certificates
	"
}

# Override of the upstream section_kernels (mkimg.base.sh): identical logic,
# but the kernel/modloop is built with a trimmed firmware package set
# (linux-firmware-none + the Intel 'other' catch-all that carries the flat
# iwlwifi-*.ucode files, + the i915 GPU split) instead of the hardcoded
# full 'linux-firmware' package. This keeps the modloop (and the whole ISO)
# a fraction of the upstream size.
section_kernels() {
	local _f _a _pkgs
	for _f in $kernel_flavors; do
		_pkgs="linux-$_f linux-firmware-none linux-firmware-other linux-firmware-i915 wireless-regdb $modloop_addons"
		for _a in $kernel_addons; do
			_pkgs="$_pkgs $_a-$_f"
		done
		local id=$( (echo "$initfs_features::$_hostkeys" ; apk fetch --root "$APKROOT" --simulate alpine-base $_pkgs | sort) | checksum)
		build_section kernel $ARCH $_f $id $_pkgs
	done
}
