TARGET ?= iphone:clang:16.5:15.0
ARCHS = arm64
THEOS_PACKAGE_SCHEME = rootless
THEOS_DEVICE_IP ?= iphone-root
THEOS_DEVICE_USER ?= root

include $(THEOS)/makefiles/common.mk

TOOL_NAME = meowd
meowd_FILES = $(wildcard src/*.m)
meowd_CFLAGS = -fobjc-arc -Wno-unused-function -Wno-deprecated-declarations
meowd_FRAMEWORKS = Foundation CoreFoundation ImageIO CoreServices UniformTypeIdentifiers
meowd_PRIVATE_FRAMEWORKS = IMCore
meowd_LIBRARIES = sqlite3
meowd_CODESIGN_FLAGS = -Ssrc/entitlements.plist
meowd_INSTALL_PATH = /usr/bin

include $(THEOS_MAKE_PATH)/tool.mk

BUNDLE_NAME = meowtxtPrefs
meowtxtPrefs_FILES = prefs/MWRootListController.m
meowtxtPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
meowtxtPrefs_FRAMEWORKS = UIKit Foundation
meowtxtPrefs_PRIVATE_FRAMEWORKS = Preferences
meowtxtPrefs_INSTALL_PATH = /Library/PreferenceBundles
meowtxtPrefs_RESOURCE_DIRS = prefs/Resources

include $(THEOS_MAKE_PATH)/bundle.mk

# Restart the daemon after `make do` / `make install`.
after-install::
	install.exec "launchctl kickstart -k system/dev.sillyangel.meowtxt 2>/dev/null || (launchctl unload /var/jb/Library/LaunchDaemons/dev.sillyangel.meowtxt.plist; launchctl load /var/jb/Library/LaunchDaemons/dev.sillyangel.meowtxt.plist)"

# Push only the web UI (no rebuild / restart needed, it is read from disk on each request).
web:
	scp -r -q layout/usr/share/meowd/web/* iphone-root:/var/jb/usr/share/meowd/web/

log:
	ssh iphone-root 'tail -n 100 -f /var/mobile/Library/Logs/meowd.log'

token:
	@ssh iphone 'grep -A1 "<key>token</key>" /var/mobile/Library/Preferences/dev.sillyangel.meowtxt.plist | tail -1 | sed -E "s/.*<string>(.*)<\/string>.*/\1/"'

.PHONY: web log token
