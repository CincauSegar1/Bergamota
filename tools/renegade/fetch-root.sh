#!/bin/bash
# Download the iOS 18.7.8 iPhone11,8 root dmg + SystemOS + AppOS cryptex dmgs (about 8.3 GB) and decrypt the two AEA ones.
# Set FETCH_WITH_IPSW=1 for ipsw's own (RAM-hungry) partial download. Needs ~20 GB free (the .aea files are deleted after decryption). Output: research/ios18/ipsw/22H352__iPhone11,8/*.dmg
set -euo pipefail
cd "$(dirname "$0")/../.."
D=research/ios18/ipsw; mkdir -p $D
URL=$(ipsw download ipsw --device iPhone11,8 --version 18.7.8 --urls | tail -1)
O=$D/22H352__iPhone11,8; mkdir -p $O
if [ "${FETCH_WITH_IPSW:-0}" = 1 ]; then
	# ipsw's own partial download: faster, but it can use several GB of RAM (killed on an 8 GB Linux host)
	ipsw download ipsw --device iPhone11,8 --version 18.7.8 --pattern '^094-(31934|32062|32850)-020\.dmg(\.aea)?$' --flat -y -o $D
else
	# default: tools/remotezip.py streams each member to disk in 64 MiB HTTP ranges (little RAM), resumes a partial
	# download when run again, and checks the zip CRC-32 before the file gets its final name
	for m in 094-31934-020.dmg.aea 094-32062-020.dmg.aea 094-32850-020.dmg; do
		python3 tools/remotezip.py "$URL" "=$m" $O
	done
fi
python3 tools/remotezip.py "$URL" BuildManifest.plist $D >/dev/null
for a in $D/22H352__iPhone11,8/*.aea; do ipsw fw aea "$a" -o "$D/22H352__iPhone11,8" && rm -f "$a"; done
ls -l $D/22H352__iPhone11,8
