#! /bin/bash

# Flashing using the jlink software.

JLinkExe \
	-device lpc55s69 -if swd -speed 2000 \
	-autoconnect 1
