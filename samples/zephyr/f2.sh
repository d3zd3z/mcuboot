#! /bin/bash

# Flashing using the jlink software.

build=build/lpcxpresso55s69_cpu0

cat >f-mcuboot.jlink <<EOF
r
h
loadbin signed-hello2.bin 0x00040000
r
g
exit
EOF

JLinkExe \
	-device lpc55s69 -if swd -speed 2000 \
	-commandfile f-mcuboot.jlink

rm f-mcuboot.jlink
