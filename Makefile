TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LiquidGlassDock
LiquidGlassDock_FILES = Tweak.x
LiquidGlassDock_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
LiquidGlassDock_FRAMEWORKS = UIKit Metal QuartzCore MetalPerformanceShaders IOSurface

include $(THEOS_MAKE_PATH)/tweak.mk
