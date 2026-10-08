include $(THEOS)/makefiles/common.mk
APPLICATION_NAME = Reader
Reader_INSTALL_PATH = /Library/NewsstandRSS
Reader_FILES = main.m NRSSAppDelegate.m NRSSItemsViewController.m NRSSArticleViewController.m \
	../shared/NRSSShared.m ../shared/NRSSFetcher.m ../shared/NRSSHTTPS.c ../shared/NRSSTrustAnchors.c ../shared/NRSSFeedParser.m ../shared/NRSSCover.m
Reader_FRAMEWORKS = Foundation UIKit CoreGraphics QuartzCore Security
Reader_CFLAGS = -fobjc-arc -I../shared -I../vendor/bearssl/inc -Wno-deprecated-declarations
ifeq ($(NRSS_DIAGNOSTICS),1)
Reader_CFLAGS += -DNRSS_DIAGNOSTICS=1
endif
Reader_LDFLAGS = -Wl,-U,_memset -Wl,-U,_memchr -Wl,-U,_memcmp -Wl,-U,_memcpy -Wl,-U,_memmove -Wl,-w ../vendor/build/libbearssl.a -lz
include $(THEOS_MAKE_PATH)/application.mk
