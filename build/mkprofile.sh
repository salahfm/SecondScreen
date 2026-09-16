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

echo "==> Appending persistent data partition -> flashable .img"
sh "$PROJECT_DIR/build/mkusbimg.sh" "$ISO_FILE"

echo "==> Build complete:"
ls -la "$OUTDIR"
