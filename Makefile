TARGET := iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MyAppWiper

MyAppWiper_FILES = src/Hooks.m src/WiperHelper.m
MyAppWiper_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-unused-function
MyAppWiper_FRAMEWORKS = UIKit Security Foundation CoreFoundation
MyAppWiper_PRIVATE_FRAMEWORKS = MobileGestalt

include $(THEOS_MAKE_PATH)/tweak.mk
