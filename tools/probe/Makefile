TARGET := iphone:clang:16.5:15.0
ARCHS = arm64
THEOS_PACKAGE_SCHEME = rootless
include $(THEOS)/makefiles/common.mk
TOOL_NAME = meowprobe
meowprobe_FILES = main.m
meowprobe_CFLAGS = -fobjc-arc
meowprobe_PRIVATE_FRAMEWORKS = IMCore IMFoundation
meowprobe_CODESIGN_FLAGS = -Sent.plist
include $(THEOS_MAKE_PATH)/tool.mk
