#!/bin/sh
# Build, copy and install the package on the USB-connected phone, then respring.
# NRSS_DIAGNOSTICS=1 builds the device test hooks in. Usage: scripts/install.sh [--no-respring]
set -e
cd "$(dirname "$0")/.."
. scripts/device.sh
if [ "$NRSS_DIAGNOSTICS" = 1 ]; then make package NRSS_DIAGNOSTICS=1 >/dev/null; else make package FINALPACKAGE=1 >/dev/null; fi
deb=$(ls -t packages/*.deb | head -n 1)
echo "installing $deb"
dev_put "$deb" /tmp/newsstandrss.deb
dev 'dpkg -i /tmp/newsstandrss.deb && rm /tmp/newsstandrss.deb'
# Respringing right after postinst's uicache can make the new SpringBoard abort in BKSDisplayServicesStart,
# which leaves MobileSubstrate in safe mode. Give backboardd a moment first.
if [ "$1" != "--no-respring" ]; then
	sleep 4
	dev 'killall -9 SpringBoard' || true
fi
