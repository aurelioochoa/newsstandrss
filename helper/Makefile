include $(THEOS)/makefiles/common.mk
TOOL_NAME = newsstandrss-helper
newsstandrss-helper_INSTALL_PATH = /usr/libexec
newsstandrss-helper_FILES = main.m ../shared/NRSSShared.m
newsstandrss-helper_FRAMEWORKS = Foundation
newsstandrss-helper_CFLAGS = -fobjc-arc -I../shared
newsstandrss-helper_LDFLAGS = -Wl,-U,_memset -Wl,-U,_memchr -Wl,-U,_memcmp -Wl,-U,_memcpy -Wl,-U,_memmove -Wl,-w
include $(THEOS_MAKE_PATH)/tool.mk
