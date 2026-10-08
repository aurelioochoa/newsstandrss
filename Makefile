THEOS ?= /home/aurelio/theos
TARGET := iphone:clang:10.3:6.0
ARCHS := armv7
export THEOS TARGET ARCHS
include $(THEOS)/makefiles/common.mk
SUBPROJECTS += tweak app helper settings
include $(THEOS_MAKE_PATH)/aggregate.mk

before-all::
	@sh scripts/build-bearssl.sh >/dev/null

after-stage::
	@chmod 4755 $(THEOS_STAGING_DIR)/usr/libexec/newsstandrss-helper
