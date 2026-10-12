#!/bin/bash
# Build WPSD-compatible MMDVMHost and M17Gateway binaries: 32-bit ARM (ARMv6, like Raspbian),
# linked against the same libraries as WPSD's own binaries.
#
# Usage: build-armhf.sh <work dir> <MMDVMHost src> <M17Gateway src> <ArduiPi_OLED src> <WiringPi src> <out dir>
#
# If VERSION is set in the environment, it replaces the version in both programs' Version.h.
#
# The build runs in a Raspbian bookworm root filesystem under QEMU user-mode emulation, so the
# host needs debootstrap, qemu-user-static (with binfmt registered), gpg and curl, and root via
# sudo. The root filesystem is created in <work dir>/rootfs on first use and reused afterwards.

set -euo pipefail

WORK=$(realpath "$1")
SRC_HOST=$(realpath "$2")
SRC_GATEWAY=$(realpath "$3")
SRC_OLED=$(realpath "$4")
SRC_WIRINGPI=$(realpath "$5")
OUT=$(realpath -m "$6")

ROOT="$WORK/rootfs"
RASPBIAN=http://archive.raspbian.org/raspbian
PACKAGES=build-essential,git,ca-certificates,libsamplerate0-dev,libgps-dev,libi2c-dev

# MMDVMHost is built like WPSD's Makefile.WPSD: OLED and HD44780/PCF8574 displays, no remote
# command logging, and resampling for FM
HOST_CFLAGS="-O3 -Wall -std=c++0x -pthread -DHAVE_LOG_H -DOLED -DHD44780 -DPCF8574_DISPLAY -DREMOTE_COMMAND_NO_LOG -DHAS_SRC -I/usr/local/include"
HOST_LIBS="-lwiringPi -lwiringPiDev -lArduiPi_OLED -lpthread -lutil -lsamplerate"

# WPSD builds the gateway with GPSD support
GATEWAY_CFLAGS="-O3 -Wall -DHAVE_LOG_H -DUSE_GPSD -std=c++0x -pthread"
GATEWAY_LIBS="-lpthread -lgps"

mkdir -p "$WORK" "$OUT"

if [ ! -f "$ROOT/etc/os-release" ]; then
	echo "### Creating the Raspbian bookworm root filesystem"
	curl -fsSL "$RASPBIAN.public.key" | gpg --dearmor > "$WORK/raspbian.gpg"
	sudo debootstrap --arch=armhf --variant=minbase --include="$PACKAGES" \
		--keyring="$WORK/raspbian.gpg" bookworm "$ROOT" "$RASPBIAN"
fi

echo "### Copying the sources"
sudo rm -rf "$ROOT/build"
sudo mkdir -p "$ROOT/build"
for src in "$SRC_HOST:MMDVMHost" "$SRC_GATEWAY:M17Gateway" "$SRC_OLED:ArduiPi_OLED" "$SRC_WIRINGPI:WiringPi"; do
	# Copy the git metadata too, the Makefiles use it for the version
	sudo cp -a "${src%%:*}" "$ROOT/build/${src##*:}"
done

if [ -n "${VERSION:-}" ]; then
	sudo sed -i "s/^const char\* VERSION = \".*\";/const char* VERSION = \"$VERSION\";/" \
		"$ROOT/build/MMDVMHost/Version.h" "$ROOT/build/M17Gateway/Version.h"
	grep -H "VERSION =" "$ROOT/build/MMDVMHost/Version.h" "$ROOT/build/M17Gateway/Version.h"
fi

sudo mount -t proc proc "$ROOT/proc"
trap 'sudo umount "$ROOT/proc"' EXIT

echo "### Building in the root filesystem"
sudo chroot "$ROOT" /bin/bash -euo pipefail -c "
	git config --global --add safe.directory '*'
	J=\$(nproc)

	# Only needed to link against, the hotspots have their own copies of these libraries
	cd /build/WiringPi/wiringPi && make -j\$J >/dev/null && make install >/dev/null
	cd /build/WiringPi/devLib && make -j\$J >/dev/null && make install >/dev/null
	cd /build/ArduiPi_OLED && make >/dev/null && make install >/dev/null
	ldconfig

	cd /build/MMDVMHost
	# Makefile.Pi.OLED plus the HD44780 display, as in WPSD's Makefile.WPSD
	sed -e 's/ OLED\.o / HD44780.o OLED.o /' Makefile.Pi.OLED > Makefile.WPSD-build
	make -f Makefile.WPSD-build clean >/dev/null
	make -f Makefile.WPSD-build -j\$J CFLAGS='$HOST_CFLAGS' LIBS='$HOST_LIBS' 2>&1 | tee build.log
	strip MMDVMHost RemoteCommand

	cd /build/M17Gateway
	make clean >/dev/null
	make -j\$J CFLAGS='$GATEWAY_CFLAGS' LIBS='$GATEWAY_LIBS' 2>&1 | tee build.log
	strip M17Gateway
"

sudo cp "$ROOT/build/MMDVMHost/MMDVMHost" "$ROOT/build/MMDVMHost/RemoteCommand" "$ROOT/build/M17Gateway/M17Gateway" "$OUT/"
sudo chown "$(id -u):$(id -g)" "$OUT"/*

echo "### Checking the binaries"
for f in "$OUT"/*; do
	arch=$(readelf -A "$f" | sed -n 's/.*Tag_CPU_arch: //p')
	needed=$(readelf -d "$f" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | tr '\n' ' ')
	echo "$(basename "$f"): CPU arch $arch; needs $needed"
	if [ "$arch" != "v6" ] && [ "$arch" != "v6KZ" ]; then
		echo "ERROR: $(basename "$f") is not built for ARMv6" >&2
		exit 1
	fi
done
