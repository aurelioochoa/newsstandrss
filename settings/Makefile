include $(THEOS)/makefiles/common.mk
BUNDLE_NAME = NewsstandRSSSettings
NewsstandRSSSettings_FILES = NRSSSettings.m ../shared/NRSSShared.m ../shared/NRSSFetcher.m ../shared/NRSSHTTPS.c ../shared/NRSSTrustAnchors.c ../shared/NRSSFeedParser.m \
	../shared/NRSSCover.m ../shared/NRSSFeedAdder.m
NewsstandRSSSettings_FRAMEWORKS = Foundation UIKit CoreGraphics Security
NewsstandRSSSettings_PRIVATE_FRAMEWORKS = Preferences
NewsstandRSSSettings_INSTALL_PATH = /Library/PreferenceBundles
NewsstandRSSSettings_CFLAGS = -fobjc-arc -I../shared -I../vendor/bearssl/inc -Wno-deprecated-declarations -Wno-unguarded-availability-new
NewsstandRSSSettings_LDFLAGS = -Wl,-U,_memset -Wl,-U,_memchr -Wl,-U,_memcmp -Wl,-U,_memcpy -Wl,-U,_memmove -Wl,-w ../vendor/build/libbearssl.a -lz
include $(THEOS_MAKE_PATH)/bundle.mk
