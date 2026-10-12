#!/bin/bash
# Copy the firmware built in the M17-Project MMDVM_HS and MMDVM repositories (the same files the
# m17-hotspot installer uses) into firmware/, under the names wpsd-modemupgrade expects, and
# record their versions in firmware/versions.txt.
#
# Usage: copy-firmware.sh <MMDVM_HS src> <MMDVM src> <firmware dir>

set -euo pipefail

SRC_HS=$1
SRC_RPT=$2
FW=$3

# MMDVM_HS release name -> WPSD name
HS_FILES="
MMDVM_HS_Hat.bin:mmdvm_hs_hat_fw.bin
MMDVM_HS_Hat-12mhz.bin:mmdvm_hs_hat_fw-12mhz.bin
MMDVM_HS_Dual_Hat.bin:mmdvm_hs_dual_hat_fw.bin
MMDVM_HS_Dual_Hat-12mhz.bin:mmdvm_hs_dual_hat_fw-12mhz.bin
generic_gpio.bin:generic_gpio_fw.bin
generic_duplex_gpio.bin:generic_duplex_gpio_fw.bin
"

for f in $HS_FILES; do
	cp "$SRC_HS/release/${f%%:*}" "$FW/${f##*:}"
done

# The repeater firmware already has WPSD's names
cp "$SRC_RPT"/release/*.bin "$SRC_RPT"/release/*.elf "$FW/"

# The versions are only shown to the user by wpsd-modemupgrade, so take them from the firmware's
# own version strings, e.g. "MMDVM_HS_Hat-v1.6.1 20251011 ... GitID #403e47c"
hs=$(strings "$SRC_HS/release/MMDVM_HS_Hat.bin" | sed -n 's/.*-v\([0-9.]*\) \([0-9]*\) .*GitID #\([0-9a-f]*\).*/\1_\2_GitID#\3/p' | head -1)
rpt=$(strings "$SRC_RPT/release/Repeater-Builder_v5.bin" | sed -n 's/^MMDVM .* \([0-9]\{8\}\) .*GitID #\([0-9a-f]*\).*/\1_GitID#\2/p' | head -1)
if [ -z "$hs" ] || [ -z "$rpt" ]; then
	echo "ERROR: couldn't find the firmware versions" >&2
	exit 1
fi

sed -i -e "s/^mmdvm_hs=.*/mmdvm_hs=${hs}_M17/" -e "s/^rpt=.*/rpt=${rpt}_M17/" "$FW/versions.txt"
cat "$FW/versions.txt"
