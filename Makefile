ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WXRelayFix

WXRelayFix_FILES = Tweak.xm
WXRelayFix_CFLAGS = -fobjc-arc -Wall -Wno-unused-variable
WXRelayFix_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
