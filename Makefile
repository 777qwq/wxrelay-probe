ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WXRelayProbe

WXRelayProbe_FILES = Tweak.xm
WXRelayProbe_CFLAGS = -fobjc-arc -Wall
WXRelayProbe_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
