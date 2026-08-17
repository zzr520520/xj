TARGET := iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

# 编译 Tweak 动态库
TWEAK_NAME = MyAppWiper
MyAppWiper_FILES = src/Hooks.m src/WiperHelper.m
MyAppWiper_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-unused-function
MyAppWiper_FRAMEWORKS = UIKit Security Foundation CoreFoundation

include $(THEOS_MAKE_PATH)/tweak.mk

# 递归编译桌面 App
SUBPROJECTS += App
include $(THEOS_MAKE_PATH)/aggregate.mk
