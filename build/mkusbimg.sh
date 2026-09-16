#!/bin/sh
set -eu

# Converts the mkimage ISO into a ready-to-flash raw USB image:
#
#   +---------------------------+----------------------+
#   | partition 1: ISO9660      | partition 2: vfat    |
#   | (Alpine boot, isohybrid)  | LABEL=SECONDSCREEN   |
#   +---------------------------+----------------------+
#
# The vfat partition is where Wi-Fi + pairing settings are stored at
# runtime (see overlay/usr/local/bin/secondscreen-sync). Shipping the img
# pre-partitioned means the user just flashes ONE file with Etcher/Rufus
# (DD mode) and everything - including persistence - works immediately.
#
# Requires: sfdisk, mtools (mformat/mcopy), coreutils.

ISO="$1"
OUT="${2:-${ISO%.iso}.img}"

command -v sfdisk >/dev/null || { echo "sfdisk not found" >&2; exit 1; }
command -v mformat >/dev/null || { echo "mtools (mformat) not found" >&2; exit 1; }

SECT=512
ALIGN_MB=$((1024 * 1024))
PERSIST_MB=$((64 * 1024 * 1024))   # 64 MB is plenty for text config

ISO_SIZE=$(stat -c%s "$ISO")

# Pad the ISO area up to a 1 MiB boundary so partition 2 starts aligned.
PAD=$(( (ALIGN_MB - (ISO_SIZE % ALIGN_MB)) % ALIGN_MB ))
PART1_END=$(( ISO_SIZE + PAD ))

TOTAL=$(( PART1_END + PERSIST_MB ))
START2=$(( PART1_END / SECT ))
SECTORS2=$(( PERSIST_MB / SECT ))

echo "==> Creating $OUT from $ISO"
echo "    ISO area: $ISO_SIZE bytes (+$PAD pad)"
echo "    persist : $PERSIST_MB bytes at sector $START2"

cp "$ISO" "$OUT"
truncate -s "$TOTAL" "$OUT"

# Partition 1: the isohybrid entry already exists in the MBR from mkimage.
# Rewrite the table keeping part1 and appending part2 (type 0x0c = FAT32 LBA).
sfdisk -d "$OUT" > /tmp/ss-part-table.dump
{
	cat /tmp/ss-part-table.dump
	echo "start=$START2, size=$SECTORS2, type=c"
} | sfdisk "$OUT" >/dev/null

# Format partition 2 in-place (no loop device needed; mtools "@@offset"
# syntax addresses the filesystem embedded at OFFSET in the image file).
OFFSET=$(( START2 * SECT ))
mformat -i "$OUT@@$OFFSET" -T "$SECTORS2" -v SECONDSCREEN ::
mmd -i "$OUT@@$OFFSET" ::/secondscreen 2>/dev/null || true

echo "==> $OUT ready"
