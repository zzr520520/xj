include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = AppWiperUI

AppWiperUI_FILES = main.m AppDelegate.m RootViewController.m ../src/WiperHelper.m ../src/WiperSnapshotManager.m ../src/LocationFaker.m ../src/NetworkFaker.m
AppWiperUI_FRAMEWORKS = UIKit CoreGraphics Foundation AdSupport MobileCoreServices CoreTelephony SystemConfiguration CoreLocation
AppWiperUI_CFLAGS = -fobjc-arc -I../src -Wno-arc-performSelector-leaks -Wno-deprecated-declarations
AppWiperUI_LIBRARIES = sqlite3
AppWiperUI_INFO_PLIST = Info.plist
AppWiperUI_CODESIGN_FLAGS = -Sentitlements.plist
AppWiperUI_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk
