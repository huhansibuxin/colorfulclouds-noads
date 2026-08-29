TARGET := iphone:clang:latest:16.0
ARCHS := arm64 arm64e
THEOS_PACKAGE_SCHEME := rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := ColorfulCloudsNoAds

ColorfulCloudsNoAds_FILES := Tweak.xm
ColorfulCloudsNoAds_CFLAGS := -fobjc-arc -w
ColorfulCloudsNoAds_FRAMEWORKS := UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
