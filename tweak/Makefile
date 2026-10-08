include $(THEOS)/makefiles/common.mk
TWEAK_NAME = NewsstandRSS
NewsstandRSS_FILES = Tweak.xm ../shared/NRSSShared.m ../shared/NRSSFetcher.m ../shared/NRSSHTTPS.c ../shared/NRSSTrustAnchors.c ../shared/NRSSFeedParser.m ../shared/NRSSCover.m ../shared/NRSSFeedAdder.m
NewsstandRSS_FRAMEWORKS = Foundation UIKit CoreGraphics QuartzCore Security
NewsstandRSS_CFLAGS = -fobjc-arc -I../shared -I../vendor/bearssl/inc -Wno-deprecated-declarations
ifeq ($(NRSS_DIAGNOSTICS),1)
NewsstandRSS_CFLAGS += -DNRSS_DIAGNOSTICS=1
endif
NewsstandRSS_CCFLAGS = -fno-exceptions -fno-objc-exceptions
NewsstandRSS_LDFLAGS = -Wl,-U,_memset -Wl,-U,_memchr -Wl,-U,_memcmp -Wl,-U,_memcpy -Wl,-U,_memmove -Wl,-w ../vendor/build/libbearssl.a -lz
include $(THEOS_MAKE_PATH)/tweak.mk
