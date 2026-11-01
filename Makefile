THEOS_PACKAGE_SCHEME = rootless
ARCHS = arm64e
TARGET = iphone:clang:latest:16.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = iPhoneRingingProbe
iPhoneRingingProbe_FILES = Tweak.xm
iPhoneRingingProbe_CFLAGS = -fobjc-arc
iPhoneRingingProbe_FRAMEWORKS = Foundation CoreFoundation

include $(THEOS_MAKE_PATH)/tweak.mk

# Deliberately no automatic respring or process restart target.
