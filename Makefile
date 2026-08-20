TARGET := iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

# 编译 Tweak 动态库
TWEAK_NAME = MyAppWiper
MyAppWiper_FILES = src/Hooks.m src/WiperHelper.m src/WiperSnapshotManager.m src/LocationFaker.m src/NetworkFaker.m
MyAppWiper_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-unused-function -Wno-arc-performSelector-leaks -Wno-deprecated-declarations -Wno-missing-selector-name -Wl,-sectcreate,__RESTRICT,__restrict,/dev/null
MyAppWiper_FRAMEWORKS = UIKit Security Foundation CoreFoundation MobileCoreServices CoreTelephony IOKit WebKit SystemConfiguration CoreLocation Metal AdSupport CoreMotion StoreKit
MyAppWiper_LIBRARIES = sqlite3

include $(THEOS_MAKE_PATH)/tweak.mk

# 递归编译桌面 App
SUBPROJECTS += App
include $(THEOS_MAKE_PATH)/aggregate.mk
