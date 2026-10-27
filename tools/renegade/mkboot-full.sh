#!/bin/bash
# Boot image for the FULL iOS 18 root on the userdata partition (rd=ufsroot0), no RAM disk.
#   tools/renegade/mkboot-full.sh [KERNEL] [ADT] [OUT.img]
# defaults: xnu/out-0139/kernel.development.sweet, ../ios-beryllium/shim/out/beryllium-hi-3x.adt,
#           research/ios18/enxerto-boot-ios18full.img
# Test it with `fastboot boot OUT.img` (the phone must hold the image from tools/renegade/mkroot-full.sh
# flashed to userdata: docs/IOS18_PORT.md section 12). Nothing is flashed or booted here.
set -euo pipefail
cd "$(dirname "$0")/../.."
BOARD=${BOARD:-marble}
KERNEL=${1:-xnu/out-0139/kernel.development.sweet}
ADT=${2:-dtb/marble/marble-hi-3x.adt}
OUT=${3:-research/ios18/enxerto-boot-ios18full.img}
# RAM-disk cmdline of docs/IOS18_PORT.md section 9 with rd=md0 -> rd=ufsroot0 ufsrw=1 rootrw=1.
# ignition_level=1: dyld's libignition looks for the cache in /System/Library/Caches/com.apple.dyld only.
CMDLINE=${CMDLINE:-"debug=0xc serial=3 cpus=8 keepsyms=1 -noprogress rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_noconsole=1 sweetfb_hz=30 sweetfb_vsync=1 sweetfb_scale=1 sweetfb_flip=1 sweetusb=2 sweetbattery=1 sweetfb_hw=1 sweetarm64e=1 launchd_disable_all_timeouts=1"}
mkdir -p enxerto/out
# Apple logo as Enxerto's last frame (docs: tools/mkapplelogo.py): read from the iOS root you built, never
# committed. APPLE_LOGO=0 skips it (the Bergamota screen stays), APPLE_LOGO_PNG=file uses an extracted PNG.
rm -f enxerto/applelogo.h
if [ "${APPLE_LOGO:-1}" != 0 ]; then
	ROOT_SIMG=${ROOT_SIMG:-research/ios18/ios18-root-full.simg}
	[ -e "$ROOT_SIMG" ] || ROOT_SIMG=../ios-beryllium-ios18/research/ios18/ios18-root-full.simg
	if [ -n "${APPLE_LOGO_PNG:-}" ]; then LOGO_SRC=(--png "$APPLE_LOGO_PNG"); else LOGO_SRC=(--root "$ROOT_SIMG"); fi
	python3 tools/mkapplelogo.py "${LOGO_SRC[@]}" || echo "warning: no Apple logo (Bergamota screen stays)" >&2
fi
python3 tools/mkpayload.py "$KERNEL" "$ADT" enxerto/out/payload-ios18full.bin --cmdline "$CMDLINE"
BOARD="$BOARD" enxerto/build.sh "$PWD/enxerto/out/payload-ios18full.bin"
cp enxerto/out/enxerto-boot.img "$OUT"
python3 tools/unpack_bootv2.py "$OUT" enxerto/out/check-ios18full >/dev/null 2>&1 && cmp enxerto/out/check-ios18full/ramdisk enxerto/out/payload-ios18full.bin && echo "payload check: ramdisk == payload"
ls -l "$OUT"
echo "cmdline: $CMDLINE"
