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
	curl openssl git findutils

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

echo "==> Staging overlay tree"
OVERLAY_STAGE="$(mktemp -d)"
mkdir -p "$OVERLAY_STAGE/etc/apk/keys" \
         "$OVERLAY_STAGE/etc/secondscreen" \
         "$OVERLAY_STAGE/etc/wpa_supplicant" \
         "$OVERLAY_STAGE/etc/network" \
         "$OVERLAY_STAGE/etc/init.d" \
         "$OVERLAY_STAGE/root" \
         "$OVERLAY_STAGE/usr/local/bin"
cp -r "$PROJECT_DIR/build/overlay/etc/." "$OVERLAY_STAGE/etc/"
cp -r "$PROJECT_DIR/build/overlay/usr/." "$OVERLAY_STAGE/usr/"

# Ship the matching public key inside the image (replaces the placeholder
# in the apkovl generator below, and is also copied directly for safety).
cp "$ABUILD_DIR/secondscreen-local.rsa.pub" \
	"$OVERLAY_STAGE/etc/apk/keys/secondscreen-local.pub"

echo "==> Generating apkovl overlay tarball"
# apkovl generator expects to run with CWD = ISO staging root, and looks
# for overlay files relative to itself.
cp "$PROJECT_DIR/build/secondscreen.apkovl.sh" "$OVERLAY_STAGE/"
cd "$OVERLAY_STAGE"
sed -i "s|PLACEHOLDER_BUILD_KEY|$(cat "$ABUILD_DIR/secondscreen-local.rsa.pub" | sed -n '2p')|" \
	secondscreen.apkovl.sh
sh secondscreen.apkovl.sh secondscreen
ls -la secondscreen.apkovl.tar.gz

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
