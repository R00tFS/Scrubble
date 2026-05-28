TARGET := iphone:clang:14.5:14.0

include $(THEOS)/makefiles/common.mk

TOOL_NAME = Scrubble

Scrubble_FILES = $(wildcard src/*.m)
Scrubble_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Iinclude
Scrubble_CODESIGN_FLAGS = -Sentitlements.plist
Scrubble_INSTALL_PATH = /usr/local/libexec/
$(TOOL_NAME)_PRIVATE_FRAMEWORKS = MediaRemote

include $(THEOS_MAKE_PATH)/tool.mk
SUBPROJECTS += ScrubblePrefs
include $(THEOS_MAKE_PATH)/aggregate.mk


internal-stage::
	$(ECHO_NOTHING)$(FAKEROOT) chown root:wheel $(THEOS_STAGING_DIR)/Library/LaunchDaemons/fr.rootfs.scrubble.plist$(ECHO_END)
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
	$(ECHO_NOTHING)/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 /var/jb/usr/local/libexec/Scrubble" "$(THEOS_STAGING_DIR)/Library/LaunchDaemons/fr.rootfs.scrubble.plist" $(ECHO_END)
endif
