TARGET := iphone:clang:14.5:14.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = ScrubblePrefs

ScrubblePrefs_FILES = SCRUBRootListController.m
ScrubblePrefs_FRAMEWORKS = UIKit
ScrubblePrefs_PRIVATE_FRAMEWORKS = Preferences
ScrubblePrefs_EXTRA_FRAMEWORKS = AltList
ScrubblePrefs_INSTALL_PATH = /Library/PreferenceBundles
ScrubblePrefs_CFLAGS = -fobjc-arc -Iinclude -I../include -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/bundle.mk
