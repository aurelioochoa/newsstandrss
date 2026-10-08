THEOS ?= /home/aurelio/theos
TARGET := iphone:clang:10.3:6.0
ARCHS := armv7
THEOS_PLATFORM_DEB_COMPRESSION_TYPE := gzip
export THEOS TARGET ARCHS THEOS_PLATFORM_DEB_COMPRESSION_TYPE
ifneq ($(filter cydia,$(MAKECMDGOALS)),)
override FINALPACKAGE := 1
override NRSS_DIAGNOSTICS := 0
override DEBUG := 0
endif
include $(THEOS)/makefiles/common.mk
SUBPROJECTS += tweak app helper settings
include $(THEOS_MAKE_PATH)/aggregate.mk

before-all::
	@sh scripts/build-bearssl.sh >/dev/null

after-stage::
	@chmod 4755 $(THEOS_STAGING_DIR)/usr/libexec/newsstandrss-helper

.PHONY: cydia check-cydia
cydia: package
	python3 scripts/publish-cydia.py
	python3 scripts/cydia-index.py repo

check-cydia:
	python3 scripts/cydia-index.py repo --check
	python3 tests/cydia-repo.py
