# Makefile for building mcuboot as a Zephyr project.

# Configuration choices.

#####################
# Signature algorithm
#####################
# Choose one of RSA or ECDSA P-256 blocks, and uncomment the config
# lines there, and comment out any other blocks.

# RSA
CONF_FILE = boot/zephyr/prj.conf
CFLAGS += -DMCUBOOT_SIGN_RSA -DMCUBOOT_USE_MBED_TLS

# ECDSA P-256
#CONF_FILE = boot/zephyr/prj-p256.conf
#CFLAGS += -DMCUBOOT_SIGN_EC256 -DMCUBOOT_USE_TINYCRYPT

# Enable this option to have the bootloader verify the signature of
# the primary image upon every boot.  Without it, signature
# verification only happens on upgrade.
CFLAGS += -DMCUBOOT_VALIDATE_SLOT0

# Enabling this option uses newer flash map APIs. This saves RAM and
# avoids deprecated API usage.
#
# (This can be deleted when flash_area_to_sectors() is removed instead
# of simply deprecated.)
CFLAGS += -DMCUBOOT_USE_FLASH_AREA_GET_SECTORS

# Enable this option to not use the swapping code and just overwrite
# the image on upgrade.
#CFLAGS += -DMCUBOOT_OVERWRITE_ONLY

##############################
# End of configuration blocks.
##############################

# The board should be set to one of the targets supported by
# mcuboot/Zephyr.  These can be found in ``boot/zephyr/targets``
BOARD ?= qemu_x86

# Additional board-specific Zephyr configuration
CONF_FILE += $(wildcard boot/zephyr/$(BOARD).conf)

# The source to the Zephyr-specific code lives here.
SOURCE_DIR = boot/zephyr

# Needed for mbedtls config-boot.h file.
CFLAGS += -I$(CURDIR)/boot/zephyr/include

DTC_OVERLAY_FILE := $(CURDIR)/boot/zephyr/dts.overlay
export DTC_OVERLAY_FILE

include ${ZEPHYR_BASE}/Makefile.inc
