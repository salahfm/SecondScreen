#!/bin/sh -e

# Generates the apkovl overlay tarball for the SecondScreen image.
# It is executed by mkimage.sh inside the fakeroot environment with CWD set
# to the ISO staging root; the generated tar ends up as
# <hostname>.apkovl.tar.gz and is unpacked by Alpine's init at every boot.
#
# Everything here must stay POSIX sh + busybox.

HOSTNAME="$1"
if [ -z "$HOSTNAME" ]; then
	echo "usage: $0 hostname"
	exit 1
fi

cleanup() {
	rm -rf "$tmp"
}

makefile() {
	OWNER="$1"
	PERMS="$2"
	FILENAME="$3"
	cat > "$FILENAME"
	chown "$OWNER" "$FILENAME"
	chmod "$PERMS" "$FILENAME"
}

rc_add() {
	mkdir -p "$tmp"/etc/runlevels/"$2"
	ln -sf /etc/init.d/"$1" "$tmp"/etc/runlevels/"$2"/"$1"
}

tmp="$(mktemp -d)"
trap cleanup EXIT

# ---------------------------------------------------------------- identity
makefile root:root 0644 "$tmp"/etc/hostname <<EOF
$HOSTNAME
EOF

# ------------------------------------------------------------- apk / world
# Packages that are NOT baked into the ISO but are installed at every boot
# from the ISO's own boot repository (mounted at /media/cdrom/apks by the
# initramfs). This keeps the ISO itself small and lets us re-tune the stack
# without rebuilding the kernel/modloop.
mkdir -p "$tmp"/etc/apk
makefile root:root 0644 "$tmp"/etc/apk/world <<EOF
alpine-base
dhcpcd
eudev
wpa_supplicant
iw
wireless-regdb
mesa-gl
mesa-dri-gallium
libva
intel-media-driver
libva-intel-driver
libva-utils
moonlight-qt
xorg-server
setxkbmap
xkeyboard-config
font-dejavu
ca-certificates
EOF

makefile root:root 0644 "$tmp"/etc/apk/repositories <<EOF
/media/cdrom/apks
EOF

# Public half of the key that signs the boot repository APKINDEX.
# The placeholder is replaced by build/mkprofile.sh at build time.
makefile root:root 0644 "$tmp"/etc/apk/keys/secondscreen-local.pub <<EOF
-----BEGIN PUBLIC KEY-----
PLACEHOLDER_BUILD_KEY
-----END PUBLIC KEY-----
EOF

# -------------------------------------------------------------- networking
# wlan0 (Wireless-AC 9560) gets its address via DHCP once wpa_supplicant has
# associated using /etc/wpa_supplicant/wpa_supplicant.conf (see persist).
mkdir -p "$tmp"/etc/network
makefile root:root 0644 "$tmp"/etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto wlan0
iface wlan0 inet dhcp
EOF

mkdir -p "$tmp"/etc/wpa_supplicant
makefile root:root 0600 "$tmp"/etc/wpa_supplicant/wpa_supplicant.conf <<EOF
ctrl_interface=/var/run/wpa_supplicant
ctrl_interface_group=0
update_config=1
EOF

# --------------------------------------------------------------- autologin
# The Wi-Fi setup wizard runs automatically on tty1 when no connection is
# configured yet (see /root/.profile -> secondscreen-wizard).
mkdir -p "$tmp"/root
makefile root:root 0644 "$tmp"/root/.profile <<'EOF'
if [ -x /usr/local/bin/secondscreen-wizard ] && ! grep -q '^network=' /etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null; then
	/usr/local/bin/secondscreen-wizard
fi
exec /bin/sh
EOF

# ----------------------------------------------------------- persist rules
# /etc is NOT kept persistent across reboots (the ISO's own apkovl wins at
# boot). Instead, Wi-Fi + pairing data live in plain files on the USB
# stick's FIRST partition (vfat, LABEL=SECONDSCREEN), which we mount at
# /media/secondscreen and read/write directly (see secondscreen-sync and
# the wizard). No lbu involved.
mkdir -p "$tmp"/etc/secondscreen

# -------------------------------------------------------------- sysconfig
# Quiet console on tty1 (the wizard re-uses it for first-boot setup).
makefile root:root 0644 "$tmp"/etc/inittab <<EOF
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default
tty1::respawn:/sbin/getty -n -l /usr/local/bin/secondscreen-autologin 38400 tty1
tty2::respawn:/usr/local/bin/secondscreen-settings
tty3::respawn:/sbin/getty 38400 tty3
tty7::respawn:/usr/local/bin/secondscreen-launch
EOF

# ---------------------------------------------------------------- services
rc_add devfs sysinit
rc_add dmesg sysinit
rc_add mdev sysinit
rc_add hwdrivers sysinit
rc_add modloop sysinit

rc_add modules boot
rc_add sysctl boot
rc_add hostname boot
rc_add bootmisc boot
rc_add syslog boot
rc_add hwclock boot

# Load persisted Wi-Fi/pairing config from the USB stick, then bring up
# the network (single self-contained service instead of ifupdown).
rc_add secondscreen-sync boot
rc_add secondscreen-net boot

# NOTE: the kiosk entry point is NOT an OpenRC service — it is spawned
# directly from the custom /etc/inittab on tty7 (see above), which runs
# after the default runlevel (and therefore after networking) completes.

rc_add mount-ro shutdown
rc_add killprocs shutdown
rc_add savecache shutdown

# ------------------------------------------------------------ overlay tree
# Files that are static content (copied verbatim into the apkovl tar).
OVERLAY_SRC="$(dirname "$0")/overlay"
if [ -d "$OVERLAY_SRC" ]; then
	# e.g. overlay/etc/init.d/secondscreen-net -> $tmp/etc/init.d/secondscreen-net
	for f in $(cd "$OVERLAY_SRC" && find . -type f | sed 's|^\./||'); do
		mkdir -p "$tmp/$(dirname "$f")"
		cp "$OVERLAY_SRC/$f" "$tmp/$f"
		chown root:root "$tmp/$f"
		# Init scripts and bin/ helpers are executable; config files are not.
		case "$f" in
			etc/init.d/*|usr/local/bin/*) chmod 755 "$tmp/$f" ;;
			*) chmod 644 "$tmp/$f" ;;
		esac
	done
fi

# ----------------------------------------------------------------- tarball
tar -c -C "$tmp" etc | gzip -9n > "$HOSTNAME.apkovl.tar.gz"
