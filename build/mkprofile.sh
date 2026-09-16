#!/bin/sh
set -eu

# Build script that runs inside an Alpine Linux container (see
# .github/workflows/build.yml). It assembles the SecondScreen mkimage
# profile and produces out/secondscreen-<tag>-x86_64.iso
#
# Required env:
#   APORTS_REF    - aports git ref to build from   (default: v3.20.0)
#   ISO_TAG       - release tag baked into filename (default: dev)
#   OUTDIR        - where to drop the ISO          (default: ./out)
#   PROJECT_DIR   - this repository checkout       (default: /project)

APORTS_REF="${APORTS_REF:-v3.20.0}"
ISO_TAG="${ISO_TAG:-dev}"
OUTDIR="${OUTDIR:-$PWD/out}"
PROJECT_DIR="${PROJECT_DIR:-/project}"
WORKDIR="${WORKDIR:-/tmp/mkimage-work}"

PRIMARY_REPO="https://dl-cdn.alpinelinux.org/alpine/v3.20/main"
COMMUNITY_REPO="https://dl-cdn.alpinelinux.org/alpine/v3.20/community"

# Size of the writable FAT partition that holds Wi-Fi + pairing state.
PERSIST_MB="${PERSIST_MB:-64}"
PERSIST_LABEL="SECONDSCRN"   # FAT labels are limited to 11 bytes

echo "==> Installing build dependencies"
apk add --no-cache \
	alpine-base apk-tools-static abuild alpine-conf busybox fakeroot \
	syslinux xorriso mtools dosfstools e2fsprogs sfdisk \
	squashfs-tools grub grub-bios grub-efi util-linux-misc mkinitfs \
	curl openssl git findutils

# mkimage.sh refuses to run unless the aports checkout looks real
# ([ -e "$APORTS/main/build-base" ]). We only need its scripts/ dir, so
# create the marker path it checks for.
mkdir -p /aports/main/build-base

echo "==> Fetching upstream mkimage scripts ($APORTS_REF)"
mkdir -p /aports/scripts
curl -fsSL "https://raw.githubusercontent.com/alpinelinux/aports/$APORTS_REF/scripts/mkimage.sh" \
	-o /aports/scripts/mkimage.sh
curl -fsSL "https://raw.githubusercontent.com/alpinelinux/aports/$APORTS_REF/scripts/mkimg.base.sh" \
	-o /aports/scripts/mkimg.base.sh
curl -fsSL "https://raw.githubusercontent.com/alpinelinux/aports/$APORTS_REF/scripts/mkimg.standard.sh" \
	-o /aports/scripts/mkimg.standard.sh
chmod +x /aports/scripts/mkimage.sh

echo "==> Generating throwaway signing keypair"
ABUILD_DIR="$HOME/.abuild"
mkdir -p "$ABUILD_DIR"
if [ ! -f "$ABUILD_DIR/secondscreen-local.rsa" ]; then
	openssl genrsa -out "$ABUILD_DIR/secondscreen-local.rsa" 2048
	openssl rsa -in "$ABUILD_DIR/secondscreen-local.rsa" \
		-pubout -out "$ABUILD_DIR/secondscreen-local.rsa.pub"
fi
echo "PACKAGER_PRIVKEY=\"$ABUILD_DIR/secondscreen-local.rsa\"" > "$ABUILD_DIR/abuild.conf"

echo "==> Staging overlay tree + apkovl generator"
mkdir -p "$OUTDIR"

# mkimage.sh resolves the apkovl script through build_apkovl(), which tries
# "$PWD/$apkovl" first (PWD = the directory mkimage.sh is launched from, i.e.
# $OUTDIR) and runs it with CWD set to the image staging root. The generator
# then finds the overlay tree via "$(dirname "$0")/overlay", so both have to
# sit side by side in $OUTDIR: <OUTDIR>/secondscreen.apkovl.sh + overlay/.
# The generator must be executable: build_apkovl runs it via fakeroot as
# "$_script", not "sh $_script".
cp "$PROJECT_DIR/build/secondscreen.apkovl.sh" "$OUTDIR/secondscreen.apkovl.sh"
chmod +x "$OUTDIR/secondscreen.apkovl.sh"
rm -rf "$OUTDIR/overlay"
cp -r "$PROJECT_DIR/build/overlay" "$OUTDIR/overlay"

# Bake in the public half of the key that signs the boot repository APKINDEX
# (the image trusts it to install packages at boot).
sed -i "s|PLACEHOLDER_BUILD_KEY|$(sed -n '2p' "$ABUILD_DIR/secondscreen-local.rsa.pub")|" \
	"$OUTDIR/secondscreen.apkovl.sh"

# Pre-flight: generate the apkovl once here and assert the files the image
# cannot boot without are actually in it, so a broken generator fails in
# seconds instead of after the multi-minute kernel/modloop build. mkimage.sh
# regenerates it into the ISO; this copy is only a smoke test.
echo "==> Pre-flight: generating apkovl"
( cd "$OUTDIR" && sh ./secondscreen.apkovl.sh secondscreen
  for want in etc/hostname etc/inittab etc/apk/world etc/apk/repositories \
	etc/apk/keys/secondscreen-local.pub etc/runlevels/boot/secondscreen-net \
	etc/init.d/secondscreen-net etc/init.d/secondscreen-sync \
	root/.profile \
	usr/local/bin/secondscreen-launch usr/local/bin/secondscreen-settings \
	usr/local/bin/secondscreen-wizard usr/local/bin/secondscreen-autologin \
	usr/local/bin/secondscreen-sync usr/local/bin/secondscreen-net; do
	tar -tzf secondscreen.apkovl.tar.gz | grep -qx "$want" || {
		echo "error: apkovl is missing $want" >&2
		exit 1
	}
  done
  echo "    apkovl OK: $(tar -tzf secondscreen.apkovl.tar.gz | wc -l) entries"
  rm -f secondscreen.apkovl.tar.gz )

cd "$OUTDIR"

echo "==> Building the persistent data partition ($PERSIST_MB MB, label $PERSIST_LABEL)"
# A raw FAT filesystem that xorriso appends to the ISO as a real partition
# (-append_partition). xorriso handles the MBR *and* the GPT of the hybrid
# image itself, which hand-editing the partition table cannot do reliably:
# the isohybrid MBR contains a partition starting at sector 0, and sfdisk
# refuses to rewrite such a table. The guest mounts this partition by label,
# whatever number xorriso assigns it.
command -v mkfs.vfat >/dev/null || { echo "mkfs.vfat not found (dosfstools)" >&2; exit 1; }
mkdir -p "$WORKDIR"
PERSIST_IMG="$WORKDIR/secondscreen-persist.img"
rm -f "$PERSIST_IMG"
dd if=/dev/zero of="$PERSIST_IMG" bs=1M count="$PERSIST_MB" status=none
mkfs.vfat -F 32 -n "$PERSIST_LABEL" "$PERSIST_IMG" >/dev/null
export PERSIST_IMG

# Read the label back: a too-long label is silently truncated, which would
# leave the guest looking for a filesystem that does not exist and quietly
# forgetting the Wi-Fi credentials on every reboot. FAT labels are 11 bytes,
# so 'SECONDSCREEN' (12) would NOT work here.
ON_DISK_LABEL=$(fatlabel "$PERSIST_IMG" 2>/dev/null || blkid -o value -s LABEL "$PERSIST_IMG" 2>/dev/null || true)
if [ "$ON_DISK_LABEL" != "$PERSIST_LABEL" ]; then
	echo "error: persist filesystem label is '$ON_DISK_LABEL', expected '$PERSIST_LABEL'" >&2
	exit 1
fi

echo "==> Registering custom profile with mkimage"
# mkimage.sh auto-sources ~/.mkimage/mkimg.*.sh as profile plugins.
mkdir -p "$HOME/.mkimage"
cp "$PROJECT_DIR/build/mkimg.secondscreen.sh" "$HOME/.mkimage/"

echo "==> Building ISO"
mkdir -p "$OUTDIR" "$WORKDIR"
cd "$OUTDIR"
sh /aports/scripts/mkimage.sh \
	--tag "$ISO_TAG" \
	--outdir "$OUTDIR" \
	--workdir "$WORKDIR" \
	--repository "$PRIMARY_REPO" \
	--repository "$COMMUNITY_REPO" \
	--arch x86_64 \
	--profile secondscreen \
	--checksum

ISO_FILE=$(ls "$OUTDIR"/secondscreen-*.iso | head -n 1)

echo "==> Verifying the flashable image"
ls -la "$ISO_FILE"
PERSIST_SECTORS=$(( PERSIST_MB * 1024 * 1024 / 512 ))
LAYOUT="$({ sfdisk -d "$ISO_FILE"; } 2>&1 || true)"
echo "$LAYOUT" | head -n 40
# A persist partition that is missing from the table would still boot, but
# would silently forget the Wi-Fi credentials on every reboot.
echo "$LAYOUT" | grep -q "$PERSIST_SECTORS" || {
	echo "error: no partition of $PERSIST_SECTORS sectors ($PERSIST_MB MB) in the image's partition table" >&2
	exit 1
}
echo "==> persist partition verified (label $PERSIST_LABEL, $PERSIST_SECTORS sectors)"

echo "==> Build complete:"
ls -la "$OUTDIR"
