TARGET := iphone:clang:latest:16.0
ARCHS := arm64 arm64e
THEOS_PACKAGE_SCHEME := rootless

# v2.1.0 性能修复：整个 dylib 一直是被 -O0 编译的。
# 原因在 theos 自己的默认值链上：既没给 FINALPACKAGE 也没给 DEBUG 时，common.mk 会
#   `DEBUG := 1` → schema 带上 DEBUG → _THEOS_SHOULD_STRIP_DEFAULT := false
# 而 theos 恰好用 SHOULD_STRIP 这一个开关去决定优化级别：
#   SHOULD_STRIP=true  → OPTFLAG ?= -Os
#   SHOULD_STRIP=false → OPTFLAG ?= -O0   ← CI 的 `make package` 一直在这一支
# （deb 文件名带 "+debug" 后缀就是这个分支的副产物，之前一直没在意。）
# 实机反汇编证实代价：didMoveToWindow 的 hook 体 665 条指令 / 96 次 [sp] 往返，
# didAddSubview: 判定链 92+107+62 = 261 条指令 —— 本来该是几十条的量级。
# 这里显式钉住 OPTFLAG 绕开那个二选一：既拿到 -O2，又保留不 strip 的调试构建
# （崩溃栈仍能符号化，`[Overlay] in-page?` 探针日志仍可读，取证能力不能为了体积丢掉）。
# 注意必须写在 include common.mk 之前 —— 那边的 ?= 只在未定义时才生效。
OPTFLAG = -O2

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := ColorfulCloudsNoAds

ColorfulCloudsNoAds_FILES := Tweak.xm
ColorfulCloudsNoAds_CFLAGS := -fobjc-arc -w
ColorfulCloudsNoAds_FRAMEWORKS := UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
